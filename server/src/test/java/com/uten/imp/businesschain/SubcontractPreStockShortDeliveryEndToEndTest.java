package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.order.dto.OrderItemLine;
import com.uten.imp.features.subcontract.order.dto.OrderSaveRequest;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.DecisionRequest;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest.ArrivalLine;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterResult;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmItem;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService;
import com.uten.imp.features.warehouse.inbound.WarehouseArrivalRegistrationService;
import com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest;
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

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * ADR-098 × ADR-090(2026-10-05) 委外回厂「先入库后质检」遇上回厂短交(真库)：货在登记时已按库位上架;
 * 短交待判定期间品质合格照常出结论并记下(此前整笔 409, 文案还叫仓库「货先留在待入库不要上架」),
 * 只是转为可用库存要等委外判定; 判定(接受损耗 / 分批到货)或后续到货让它不再被扣住时,
 * 同一事务按上架位置自动转正, 仓库不用点任何按钮。先质检后入库路线不变(见 SubcontractShortDeliveryEndToEndTest)。
 *
 * <p>本类的 Spring 上下文与其它真库用例一样打开 {@code uten.concurrency.verify-nested-footprint}:
 * 判定 / 登记首次预锁必须覆盖补做转正时的品质与入库足迹。
 */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class SubcontractPreStockShortDeliveryEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SubcontractOrderService orders;
    @Autowired ProcurementFinanceApprovalService financeApproval;
    @Autowired WarehouseArrivalRegistrationService arrivals;
    @Autowired SubcontractShortDeliveryService shortDeliveries;
    @Autowired ProcurementInspectionService inspections;
    @Autowired ProcurementIqcStockInService iqcStockIn;
    FullChainEndToEndTest fixture;
    @BeforeEach void setup(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}
    @AfterEach void logout(){org.springframework.security.core.context.SecurityContextHolder.clearContext();}

    private static final String SHELF = "SC-PRE-01";

    /** 订 100、允许损耗 5%、料全发; 先入库后质检登记 50(仓库确认短交) → 品质合格成功但不转正 → 委外接受损耗 → 自动转正。 */
    @Test void shelvedPassWaitsForTheDecisionAndAcceptLossConvertsItAutomatically() {
        var w=fixture.seedWorld("sc-prestock-hold-accept");fixture.loginAs(w.superAdminUserId());
        Ordered o=orderApproveAndIssueAll(w,"sc-prestock-accept");

        // ① 先入库后质检登记 50: 低于下限 95, 未确认先 409; 确认后登记成功, 货按库位上架, 案件待委外判定。
        ApiException unacknowledged=assertThrows(ApiException.class,()->arrivals.register(preStockArrival(w,o.itemId(),"50",false,"a1")));
        assertEquals(ErrorCode.SUBCONTRACT_SHORT_DELIVERY_UNACKNOWLEDGED,unacknowledged.getCode());
        WarehouseArrivalRegisterResult first=arrivals.register(preStockArrival(w,o.itemId(),"50",true,"a1"));
        assertEquals("STOCKED_PENDING_INSPECTION",first.outcome());
        Map<String,Object> c=caseRow(o.itemId());
        assertEquals("PENDING_OWNER",c.get("status"));assertEquals("SEVERE",c.get("severity"));
        String preStockedHold=shortDeliveries.preStockedHoldReason(first.receiptId());
        assertNotNull(preStockedHold,"待判定期间先入库后质检的货也先不转正");
        assertTrue(preStockedHold.contains("货已上架, 等委外判定短交后才能转为可用库存"),preStockedHold);
        assertFalse(preStockedHold.contains("不要上架"),preStockedHold);

        // ② 品质合格: 结论照常记下(此前整笔 409), 但不转正——库存 0、没有入库批次、也不给仓库发「待入库」任务。
        UUID inspection=inspectionOf(first.receiptId());
        UUID pass=passIqc(first.receiptId(),inspection,"sc-prestock-accept-pass");
        assertEquals("RESOLVED",db.queryForObject("SELECT status FROM procurement_inspection_items WHERE id=?",String.class,inspection));
        rate("50",db.queryForObject("SELECT base_qty FROM procurement_inspection_events WHERE id=?",BigDecimal.class,pass));
        rate("0",onHand(w.goodsE(),w.warehouseId()));
        assertEquals(0,count("SELECT COUNT(*) FROM procurement_iqc_stock_in_batches WHERE receipt_id=?",first.receiptId()),"待判定期间不转正");
        assertEquals(0,count("SELECT COUNT(*) FROM business_outbox WHERE event_type='PROCUREMENT_IQC_STOCK_IN_PENDING' AND aggregate_id=?",pass),
                "货已在库位上, 系统会在判定后自动转正, 不给仓库派「待入库」任务");
        assertTrue(orders.detail(o.orderId()).getShortDeliveryHold().summary().contains("先入库后质检"),
                "订货单锁定横幅说清楚已上架的货先不转为可用库存");

        // ③ 仓库若手工去点「确认入库」: 409 说的是已上架、等判定、系统会自动转入。
        UUID keeper=ReflectionTestUtils.invokeMethod(fixture,"createIqcWarehouseConfirmer",w,"sc-prestock-accept-keeper");
        fixture.loginAs(keeper);
        ApiException held=assertThrows(ApiException.class,()->iqcStockIn.confirm("SUBCONTRACT",first.receiptId(),
                new ConfirmRequest("sc-prestock-accept-manual",List.of(new ConfirmItem(pass,new BigDecimal("50"),new BigDecimal("50"),SHELF,w.warehouseId())))));
        assertEquals(ErrorCode.CONFLICT,held.getCode());
        assertTrue(held.getMessage().contains("货已上架")&&held.getMessage().contains("不用再点确认入库"),held.getMessage());
        assertFalse(held.getMessage().contains("不要上架"),held.getMessage());
        fixture.loginAs(w.superAdminUserId());

        // ④ 委外接受损耗: 同一事务按上架位置自动转正——库存 50、批次 origin=PRE_STOCKED_AUTO、案件结案、订货单关闭(合格 50 + 损耗 50)。
        long version=((Number)caseRow(o.itemId()).get("version")).longValue();
        var accepted=shortDeliveries.decide((UUID)c.get("id"),new DecisionRequest("ACCEPT_LOSS",null,"委外商确认只能交 50 个",version));
        assertEquals("ACCEPTED_LOSS",accepted.row().status());
        rate("50",onHand(w.goodsE(),w.warehouseId()));
        assertEquals(1,count("SELECT COUNT(*) FROM procurement_iqc_stock_in_batches WHERE receipt_id=? AND origin='PRE_STOCKED_AUTO'",first.receiptId()),
                "判定的同一事务自动转正");
        rate("50",db.queryForObject("SELECT warehouse_stocked_base_qty FROM procurement_inspection_items WHERE id=?",BigDecimal.class,inspection));
        assertEquals(SHELF,db.queryForObject("""
                SELECT item.place_snapshot FROM procurement_iqc_stock_in_batch_items item
                JOIN procurement_iqc_stock_in_batches batch ON batch.id=item.batch_id
                WHERE batch.receipt_id=? LIMIT 1
                """,String.class,first.receiptId()),"按登记时的库位转正");
        assertNull(shortDeliveries.preStockedHoldReason(first.receiptId()));
        assertTrue(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?",Boolean.class,o.orderId()),
                "合格入库 50 + 已接受损耗 50 = 订货 100, 关单");
    }

    /** 判定「分批到货」同样即时解锁: 已上架的合格品当场转正, 后面补来的 50 合格后照常自动转正。 */
    @Test void waitMoreDecisionAlsoConvertsTheShelvedPass() {
        var w=fixture.seedWorld("sc-prestock-hold-wait");fixture.loginAs(w.superAdminUserId());
        Ordered o=orderApproveAndIssueAll(w,"sc-prestock-wait");
        WarehouseArrivalRegisterResult first=arrivals.register(preStockArrival(w,o.itemId(),"50",true,"w1"));
        passIqc(first.receiptId(),inspectionOf(first.receiptId()),"sc-prestock-wait-pass-1");
        rate("0",onHand(w.goodsE(),w.warehouseId()));

        Map<String,Object> c=caseRow(o.itemId());
        var waiting=shortDeliveries.decide((UUID)c.get("id"),new DecisionRequest("WAIT_MORE",BusinessTime.today().plusDays(7),
                "委外商下周补齐",((Number)c.get("version")).longValue()));
        assertEquals("WAITING_MORE",waiting.row().status());
        rate("50",onHand(w.goodsE(),w.warehouseId()));
        assertEquals(1,count("SELECT COUNT(*) FROM procurement_iqc_stock_in_batches WHERE receipt_id=? AND origin='PRE_STOCKED_AUTO'",first.receiptId()));

        // 剩下 50 到齐(累计 100, 不用确认) → 案件自然完成 → 合格后自动转正 → 关单。
        WarehouseArrivalRegisterResult second=arrivals.register(preStockArrival(w,o.itemId(),"50",false,"w2"));
        assertEquals("STOCKED_PENDING_INSPECTION",second.outcome());
        assertEquals("COMPLETED",db.queryForObject("SELECT status FROM subcontract_short_delivery_cases WHERE id=?",String.class,c.get("id")));
        passIqc(second.receiptId(),inspectionOf(second.receiptId()),"sc-prestock-wait-pass-2");
        rate("100",onHand(w.goodsE(),w.warehouseId()));
        assertTrue(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?",Boolean.class,o.orderId()));
    }

    /** 委外还没判定, 剩下的货先到齐: 登记让案件自然完成, 同一事务把先前扣住的已上架合格品一起转正。 */
    @Test void arrivalThatCompletesTheOrderReleasesTheEarlierShelvedPass() {
        var w=fixture.seedWorld("sc-prestock-hold-complete");fixture.loginAs(w.superAdminUserId());
        Ordered o=orderApproveAndIssueAll(w,"sc-prestock-complete");
        WarehouseArrivalRegisterResult first=arrivals.register(preStockArrival(w,o.itemId(),"50",true,"c1"));
        passIqc(first.receiptId(),inspectionOf(first.receiptId()),"sc-prestock-complete-pass-1");
        rate("0",onHand(w.goodsE(),w.warehouseId()));
        UUID caseId=(UUID)caseRow(o.itemId()).get("id");

        WarehouseArrivalRegisterResult second=arrivals.register(preStockArrival(w,o.itemId(),"50",false,"c2"));
        assertEquals("STOCKED_PENDING_INSPECTION",second.outcome());
        assertEquals("COMPLETED",db.queryForObject("SELECT status FROM subcontract_short_delivery_cases WHERE id=?",String.class,caseId));
        rate("50",onHand(w.goodsE(),w.warehouseId()));
        assertEquals(1,count("SELECT COUNT(*) FROM procurement_iqc_stock_in_batches WHERE receipt_id=? AND origin='PRE_STOCKED_AUTO'",first.receiptId()),
                "到齐登记的同一事务把先前扣住的合格品转正");
        assertEquals(0,count("SELECT COUNT(*) FROM procurement_iqc_stock_in_batches WHERE receipt_id=?",second.receiptId()),
                "刚登记的这批还在等品质检验");

        passIqc(second.receiptId(),inspectionOf(second.receiptId()),"sc-prestock-complete-pass-2");
        rate("100",onHand(w.goodsE(),w.warehouseId()));
        assertTrue(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?",Boolean.class,o.orderId()));
    }

    // ===================== helpers =====================

    private record Ordered(UUID orderId,UUID itemId) {}

    /** 委外件 E 发外直属物料 M(按件用量 1): 订 100、允许损耗 5%, 财务批准, 领满 100 套并由仓库发出。 */
    private Ordered orderApproveAndIssueAll(FullChainEndToEndTest.World w,String tag){
        UUID material=fixture.ensureSubcontractDirectMaterial(w,w.goodsE());fixture.receiveSubcontractMaterial(w,material,"100");
        UUID orderId=orders.create(orderRequest(w,"100","5")).getId();
        UUID itemId=db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?",UUID.class,orderId);
        UUID reviewer=ReflectionTestUtils.invokeMethod(fixture,"createApprover",w);
        financeApproval.submit("SUBCONTRACT",orderId);
        fixture.loginAs(reviewer);fixture.approvePendingFinance("SUBCONTRACT",orderId);fixture.loginAs(w.superAdminUserId());
        fixture.drawAndIssueSubcontract(itemId,new BigDecimal("100"),tag+"-draw-"+itemId);
        return new Ordered(orderId,itemId);
    }

    private OrderSaveRequest orderRequest(FullChainEndToEndTest.World w,String qty,String allowedLossPct){
        var request=new OrderSaveRequest();
        request.setBillDate(BusinessTime.today());request.setDeliverDate(BusinessTime.today().plusDays(3));
        request.setSupplierId(w.supplierId());request.setWarehouseId(w.warehouseId());
        request.setCurrencyId(w.currencyId());request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture,"activeSettlementMethodId"));
        var line=new OrderItemLine();
        line.setGoodsId(w.goodsE());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));line.setPrice(new BigDecimal("10"));
        line.setAllowedLossPct(new BigDecimal(allowedLossPct));
        request.setItems(List.of(line));
        return request;
    }

    /** 先入库后质检(stockInBeforeInspection=true)登记: 每行带上架库位, 上架到本单入库仓。 */
    private WarehouseArrivalRegisterRequest preStockArrival(FullChainEndToEndTest.World w,UUID itemId,String qty,boolean acknowledged,String key){
        return new WarehouseArrivalRegisterRequest(
                "prestock-hold-"+key+"-"+itemId,"SUBCONTRACT",BusinessTime.today(),w.supplierId(),w.warehouseId(),
                null,w.employeeId(),null,
                List.of(new ArrivalLine(w.goodsE(),new BigDecimal(qty),itemId,null,w.unitId(),BigDecimal.ONE,null,null,null,SHELF)),
                Boolean.TRUE,acknowledged?Boolean.TRUE:null);
    }

    private UUID inspectionOf(UUID receiptId){
        return db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='SUBCONTRACT' AND receipt_id=?",UUID.class,receiptId);
    }

    /** 品质部整行判合格(不传数量 = 全部待检量), 返回 PASS 事件。 */
    private UUID passIqc(UUID receiptId,UUID inspection,String key){
        inspections.dispose("SUBCONTRACT",receiptId,inspection,new InspectionDispositionRequest("PASS",null,"回厂件检查合格",key));
        return db.queryForObject("SELECT id FROM procurement_inspection_events WHERE inspection_item_id=? AND action='PASS'",UUID.class,inspection);
    }

    private Map<String,Object> caseRow(UUID itemId){
        return db.queryForMap("SELECT * FROM subcontract_short_delivery_cases WHERE order_item_id=? ORDER BY detected_at DESC LIMIT 1",itemId);
    }

    private BigDecimal onHand(UUID goodsId,UUID warehouseId){
        return db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=? AND warehouse_id=?",
                BigDecimal.class,goodsId,warehouseId);
    }

    private int count(String sql,Object... args){
        Integer n=db.queryForObject(sql,Integer.class,args);
        return n==null?0:n;
    }

    private static void rate(String expected,BigDecimal actual){
        assertNotNull(actual);
        assertEquals(0,new BigDecimal(expected).compareTo(actual),"expected "+expected+" but was "+actual);
    }
}
