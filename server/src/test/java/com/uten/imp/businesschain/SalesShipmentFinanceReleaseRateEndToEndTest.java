package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.sales.order.dto.OrderSaveRequest;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.features.sales.shipment.dto.ShipmentFinanceDecisionRequest;
import com.uten.imp.features.sales.shipment.dto.ShipmentSaveRequest;
import com.uten.imp.features.sales.shipment.dto.WarehouseWorkTransitionRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/**
 * V632 出货放行记账汇率(真库)：财务放行时预填/填写记账汇率并冻结到本单与放行事件，
 * 仓库确认出库按冻结值折算本币立应收；撤回放行清空；本位币恒 1。
 */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class SalesShipmentFinanceReleaseRateEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SalesShipmentService shipments;
    @Autowired com.uten.imp.features.sales.order.SalesOrderService orders;
    @Autowired TaskClaimService reviewClaims;
    FullChainEndToEndTest fixture;
    @BeforeEach void setup(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}

    /**
     * 本位币是全库唯一一行(V403 按 legacy_id=1 钉死)，不是 per-world 数据；本类里
     * baseCurrencyReleaseIsAlwaysOneAndRejectsAnyOtherRate 会把它的参考汇率改成 0 来验证
     * 「本位币不需要维护汇率」。而本类与另外 28 个用例类共用同一个 Testcontainers 库
     * (都走 FullChainEndToEndTest.registerDataSource)，改完不还原就会污染整个 JVM 的后续用例：
     * 任何再取记账汇率的出货用例都会炸「财务维护的币种汇率必须大于 0，禁止发运立账」
     * (2026-09-21 本机全链两次复现 SalesShipmentWarehouseAssignmentEndToEndTest 的免费出货用例；
     * CI 因执行顺序不同侥幸没中)。这里逐个用例还原，谁也别想再踩。
     */
    @AfterEach void logout(){
        org.springframework.security.core.context.SecurityContextHolder.clearContext();
        db.update("UPDATE currencies SET exchange_rate=1 WHERE is_base_currency AND exchange_rate<>1");
    }

    @Test void financeFillsTheRecognitionRateAtReleaseAndTheWarehousePostsReceivablesWithIt() {
        var w=fixture.seedWorld("fin-release-rate");fixture.loginAs(w.superAdminUserId());
        // 币种主档参考汇率没维护(老库 ExRate 多为 0)——V631 之前这会让仓库确认出库报错，V631 挡在财审，V632 让财务在放行时填。
        db.update("UPDATE currencies SET code='USD-rate', name='美金', exchange_rate=0 WHERE id=?",w.currencyId());
        ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",w,w.goodsE(),"10");
        UUID order=fixture.createApprovedOrder(w,w.goodsE(),"10","100");
        UUID orderItem=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
        ShipmentSaveRequest request=ReflectionTestUtils.invokeMethod(fixture,"shipmentRequest",w,orderItem,w.goodsE(),"10");
        assertNotNull(request);
        var draft=shipments.create(request);
        // 草稿不带销售端汇率。
        assertNull(db.queryForObject("SELECT exchange_rate FROM sales_shipments WHERE id=?",BigDecimal.class,draft.getId()));

        Map<String,Object> preview=shipments.financeAuditInfo(draft.getId());
        assertEquals(false,preview.get("financeRateReady"));assertEquals(false,preview.get("baseCurrency"));
        assertEquals("",preview.get("suggestedExchangeRate"));assertEquals("",preview.get("shipmentExchangeRate"));

        // 不填汇率、主档又没维护 → 409 让财务填，而不是仓库那步才报错。
        ApiException blank=assertThrows(ApiException.class,()->release(draft.getId(),null));
        assertTrue(blank.getMessage().contains("请在放行时填写记账汇率"),blank.getMessage());
        assertEquals(0,(short)db.queryForObject("SELECT finance_audit FROM sales_shipments WHERE id=?",Short.class,draft.getId()));

        // 财务按放行当日汇率填 7.2 → 冻结到本单，放行事件记录汇率与来源=财务手填。
        Map<String,Object> released=release(draft.getId(),new BigDecimal("7.200000"));
        assertEquals("7.2",released.get("shipmentExchangeRate"));assertEquals("7.2",released.get("suggestedExchangeRate"));
        rate("7.2",db.queryForObject("SELECT exchange_rate FROM sales_shipments WHERE id=?",BigDecimal.class,draft.getId()));
        assertEquals(List.of("RELEASED|7.200000|FINANCE_MANUAL"),releaseEvents(draft.getId()));

        // 撤回放行：冻结值作废，撤回事件不带汇率。
        shipments.financeAuditReverse(draft.getId());
        assertNull(db.queryForObject("SELECT exchange_rate FROM sales_shipments WHERE id=?",BigDecimal.class,draft.getId()));
        assertEquals(List.of("RELEASED|7.200000|FINANCE_MANUAL","REVOKED|null|null"),releaseEvents(draft.getId()));

        // 主档维护了 7 之后：预填 7；不填就用主档(来源=主档)；填成同值也算主档。
        db.update("UPDATE currencies SET exchange_rate=7 WHERE id=?",w.currencyId());
        assertEquals("7",shipments.financeAuditInfo(draft.getId()).get("suggestedExchangeRate"));
        release(draft.getId(),null);
        assertEquals("RELEASED|7.000000|CURRENCY_MASTER",releaseEvents(draft.getId()).getLast());
        shipments.financeAuditReverse(draft.getId());
        release(draft.getId(),new BigDecimal("7.0"));
        assertEquals("RELEASED|7.000000|CURRENCY_MASTER",releaseEvents(draft.getId()).getLast());
        shipments.financeAuditReverse(draft.getId());

        // 财务改成 7.25 放行；主档随后改成 8 也不影响本单——仓库确认出库按冻结的 7.25 立应收。
        release(draft.getId(),new BigDecimal("7.25"));
        db.update("UPDATE currencies SET exchange_rate=8 WHERE id=?",w.currencyId());
        var outbound=new WarehouseWorkTransitionRequest();outbound.setTargetStatus("SHIPPED");outbound.setWarehouseId(w.warehouseId());
        outbound.setStockPlaces(List.of(new WarehouseWorkTransitionRequest.StockPlace(draft.getItems().getFirst().getId(),"A-01-01")));
        shipments.transitionWarehouseWork(draft.getId(),outbound);
        rate("7.25",db.queryForObject("SELECT exchange_rate FROM sales_shipments WHERE id=?",BigDecimal.class,draft.getId()));
        money("7250",db.queryForObject("SELECT total_local FROM sales_shipments WHERE id=?",BigDecimal.class,draft.getId()));
        money("7250",db.queryForObject("SELECT amount_local FROM sales_shipment_items WHERE shipment_id=?",BigDecimal.class,draft.getId()));
        rate("7.25",db.queryForObject("SELECT exchange_rate FROM ar_ap_ledger WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",BigDecimal.class,draft.getId()));
        money("1000",db.queryForObject("SELECT amount_original FROM ar_ap_ledger WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",BigDecimal.class,draft.getId()));
        money("7250",db.queryForObject("SELECT amount_original_local FROM ar_ap_ledger WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",BigDecimal.class,draft.getId()));
    }

    @Test void baseCurrencyReleaseIsAlwaysOneAndRejectsAnyOtherRate() {
        var w=fixture.seedWorld("fin-release-base");fixture.loginAs(w.superAdminUserId());
        UUID base=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency",UUID.class);
        // 本位币主档参考汇率哪怕是 0(老库常见)也不需要维护。
        db.update("UPDATE currencies SET exchange_rate=0 WHERE id=?",base);
        ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",w,w.goodsE(),"10");
        OrderSaveRequest orderRequest=fixture.orderRequest(w,w.goodsE(),"10","100");orderRequest.setCurrencyId(base);
        var order=orders.create(orderRequest);orders.approve(order.getId());
        ReflectionTestUtils.invokeMethod(fixture,"confirmInitialSalesFinance",order.getId());
        UUID orderItem=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order.getId());
        ShipmentSaveRequest request=ReflectionTestUtils.invokeMethod(fixture,"shipmentRequest",w,orderItem,w.goodsE(),"10");
        assertNotNull(request);request.setCurrencyId(base);
        var draft=shipments.create(request);

        Map<String,Object> preview=shipments.financeAuditInfo(draft.getId());
        assertEquals(true,preview.get("baseCurrency"));assertEquals(true,preview.get("financeRateReady"));
        assertEquals("1",preview.get("suggestedExchangeRate"));

        ApiException other=assertThrows(ApiException.class,()->release(draft.getId(),new BigDecimal("7.2")));
        assertTrue(other.getMessage().contains("记账汇率固定为 1"),other.getMessage());
        release(draft.getId(),null);
        rate("1",db.queryForObject("SELECT exchange_rate FROM sales_shipments WHERE id=?",BigDecimal.class,draft.getId()));
        assertEquals("RELEASED|1.000000|CURRENCY_MASTER",releaseEvents(draft.getId()).getLast());
    }

    @Test void standardPaymentMethodsAreSeededWhenNoConfirmedLegacyMethodExists() {
        // V273 只带 3 条待同步名称的占位行(不进选择器)；V632 在没有任何已确认方式时补一套标准方式。
        List<String> codes=db.queryForList("SELECT code FROM finance_payment_methods WHERE legacy_name_confirmed AND is_receipt AND is_payment AND status='使用' AND is_deleted=false ORDER BY sort_order",String.class);
        assertTrue(codes.containsAll(List.of("REC-BANK","REC-CASH","REC-CHEQUE","REC-DRAFT")),codes.toString());
        assertEquals("银行转账",db.queryForObject("SELECT name FROM finance_payment_methods WHERE code='REC-BANK'",String.class));
    }

    private Map<String,Object> release(UUID shipmentId,BigDecimal exchangeRate) {
        var claim=reviewClaims.claim("SALES_SHIPMENT_FINANCE_AUDIT",shipmentId.toString());
        var info=shipments.financeAuditInfo(shipmentId);
        return shipments.financeAudit(shipmentId,new ShipmentFinanceDecisionRequest(
                ((Number)info.get("reviewRevision")).longValue(),info.get("contentHash").toString(),claim.claimId(),null,exchangeRate));
    }

    private List<String> releaseEvents(UUID shipmentId) {
        return db.queryForList("SELECT event_type||'|'||COALESCE(exchange_rate::text,'null')||'|'||COALESCE(exchange_rate_source,'null')"
                +" FROM sales_shipment_finance_release_events WHERE shipment_id=? ORDER BY occurred_at,id",String.class,shipmentId);
    }

    private static void rate(String expected,BigDecimal actual){assertNotNull(actual);assertEquals(0,new BigDecimal(expected).compareTo(actual),"expected "+expected+" but was "+actual);}
    private static void money(String expected,BigDecimal actual){rate(expected,actual);}
}
