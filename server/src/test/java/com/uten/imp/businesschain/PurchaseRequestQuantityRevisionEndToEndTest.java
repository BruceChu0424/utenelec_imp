package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import java.util.*;
import java.math.BigDecimal;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.assertj.core.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false",
    "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
    "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=false",
    "uten.jwt.secret=quantity-regression-isolated-jwt-key-0123456789-abcdef", // gitleaks:allow synthetic test-only cryptographic fixture.
    "uten.crypto.pgp-master-key=quantity-regression-isolated-pgp-key-0123456789-abcdef", // gitleaks:allow synthetic test-only cryptographic fixture.
    "uten.crypto.hmac-key=quantity-regression-isolated-hmac-key-0123456789-abcdef",
    "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class PurchaseRequestQuantityRevisionEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PurchaseRequestService requests;
    @Autowired PurchaseOrderService orders;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired PlatformTransactionManager transactionManager;
    @Autowired TxSessionVars tx;
    FullChainEndToEndTest harness;
    record Source(FullChainEndToEndTest.World world,UUID request,UUID item,UUID reviewer,UUID analysis){}
    @BeforeEach void prepare(){harness=new FullChainEndToEndTest();beans.autowireBean(harness);}
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void sourceGeneratedCorrectionGrowsAndShrinksExactlyButDoesNotShrinkThroughDemandOrReplay(){
        Source s=source();long v=version(s);UUID item=s.item();
        var first=requests.adjustItemQty(s.request(),item,new BigDecimal("99999999999999.0001"),v);
        assertThat(first.getItems().getFirst().getQty()).isEqualByComparingTo("99999999999999.0001");
        long secondVersion=version(s);assertThat(secondVersion).isEqualTo(v+1);
        requests.adjustItemQty(s.request(),item,new BigDecimal("99999999999999.0002"),secondVersion);
        assertThat(quantity(s)).isEqualByComparingTo("99999999999999.0002");
        requests.adjustItemQty(s.request(),item,new BigDecimal("1.2345"),version(s));
        assertThat(quantity(s)).isEqualByComparingTo("1.2345");assertThat(proofs(s)).isEqualTo(3);
        long unchanged=version(s);requests.adjustItemQty(s.request(),item,new BigDecimal("1.2345"),unchanged);
        assertThat(version(s)).isEqualTo(unchanged);assertThat(proofs(s)).isEqualTo(3);
        assertThatThrownBy(()->requests.adjustItemQty(s.request(),item,new BigDecimal("1.2344"),unchanged)).hasMessageContaining("来源已下达");
        assertThatThrownBy(()->requests.adjustItemQty(s.request(),item,new BigDecimal("2"),v)).hasMessageContaining("已被别人改过");
        assertThat(quantity(s)).isEqualByComparingTo("1.2345");assertThat(version(s)).isEqualTo(unchanged);assertThat(proofs(s)).isEqualTo(3);
        UUID viewer=harness.createUserWithPerms(s.world(),"request-viewer-"+item,"purchase_request:view");harness.loginAs(viewer);
        assertThatThrownBy(()->requests.adjustItemQty(s.request(),item,new BigDecimal("2"),unchanged)).isInstanceOf(org.springframework.security.access.AccessDeniedException.class);
        assertThat(proofs(s)).isEqualTo(3);
        assertThat(db.queryForObject("SELECT allocated_qty FROM preplan_supply_action_allocations WHERE external_item_id=?",BigDecimal.class,item)).isEqualByComparingTo("1.2345");
        assertThat(db.queryForObject("SELECT COUNT(*) FROM stock_movements WHERE goods_id=?",Integer.class,s.world().goodsD())).isZero();
    }

    @Test void evenUnsubmittedDraftSourceOccupancyPreventsCorrectionAndDoesNotCreateAProof(){
        Source s=source();harness.loginAs(s.world().superAdminUserId());
        var request=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        request.setBillDate(BusinessTime.today());request.setSupplierId(s.world().supplierId());request.setWarehouseId(s.world().warehouseId());
        request.setCurrencyId(db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class));
        request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class));
        var line=new com.uten.imp.features.purchase.order.dto.OrderItemLine();line.setGoodsId(s.world().goodsD());line.setUnitId(s.world().unitId());
        line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal("1.2345"));line.setPrice(BigDecimal.ONE);line.setRequestItemId(s.item());request.setItems(List.of(line));
        orders.create(request);harness.loginAs(s.reviewer());long before=version(s);
        assertThatThrownBy(()->requests.adjustItemQty(s.request(),s.item(),new BigDecimal("2"),before)).hasMessageContaining("不能");
        assertThat(proofs(s)).isZero();assertThat(version(s)).isEqualTo(before);assertThat(quantity(s)).isEqualByComparingTo("1.2345");
    }

    @Test void genericShrinkAndForgedOtherActorProofCannotReuseAnEarlierCommittedCommand(){
        Source s=source();requests.adjustItemQty(s.request(),s.item(),new BigDecimal("5"),version(s));long before=version(s);
        var template=new TransactionTemplate(transactionManager);
        assertThatThrownBy(()->template.execute(status->{tx.bind();db.update("UPDATE purchase_request_items SET qty=3 WHERE id=?",s.item());return null;})).isInstanceOf(RuntimeException.class).hasStackTraceContaining("production-linked supply source item cannot be changed or deleted");
        assertThat(quantity(s)).isEqualByComparingTo("5");assertThat(version(s)).isEqualTo(before);assertThat(proofs(s)).isEqualTo(1);
        assertThatThrownBy(()->template.execute(status->{tx.bind();db.update("""
            INSERT INTO purchase_request_qty_revisions(request_id,request_item_id,expected_version,old_qty,new_qty,
                before_item,source_minimum_base,actor_user_id,actor_employee_id)
            SELECT request_id,id,row_version,qty,3,to_jsonb(item),fn_purchase_request_qty_source_minimum(id),?,?
            FROM purchase_request_items item WHERE id=?
            """,s.world().superAdminUserId(),s.world().employeeId(),s.item());return null;})).isInstanceOf(RuntimeException.class).hasStackTraceContaining("Purchase request correction lacks current source");
        assertThat(proofs(s)).isEqualTo(1);assertThat(version(s)).isEqualTo(before);
        assertThat(db.queryForObject("SELECT actor_user_id FROM purchase_request_qty_revisions WHERE request_item_id=?",UUID.class,s.item())).isEqualTo(s.reviewer());
    }

    @Test void concurrentSameVersionCorrectionsCommitExactlyOneQuantityAndOneProof() throws Exception {
        Source s=source();long before=version(s);
        var ready=new java.util.concurrent.CountDownLatch(2);var start=new java.util.concurrent.CountDownLatch(1);
        var pool=java.util.concurrent.Executors.newFixedThreadPool(2);
        try {
            var futures=new ArrayList<java.util.concurrent.Future<Boolean>>();
            for(String quantity:List.of("2.0001","2.0002"))futures.add(pool.submit(()->{
                harness.loginAs(s.reviewer());ready.countDown();
                try {
                    assertThat(start.await(10,java.util.concurrent.TimeUnit.SECONDS)).isTrue();
                    requests.adjustItemQty(s.request(),s.item(),new BigDecimal(quantity),before);return true;
                } catch(com.uten.imp.common.web.ApiException conflict) {
                    assertThat(conflict.getCode()).isEqualTo(com.uten.imp.common.web.ErrorCode.CONFLICT);return false;
                } finally {SecurityContextHolder.clearContext();}
            }));
            assertThat(ready.await(10,java.util.concurrent.TimeUnit.SECONDS)).isTrue();start.countDown();
            int committed=0;for(var future:futures)if(future.get(30,java.util.concurrent.TimeUnit.SECONDS))committed++;
            assertThat(committed).isEqualTo(1);assertThat(proofs(s)).isEqualTo(1);assertThat(version(s)).isEqualTo(before+1);
            assertThat(quantity(s)).isIn(new BigDecimal("2.0001"),new BigDecimal("2.0002"));
        } finally {start.countDown();pool.shutdownNow();}
    }

    Source source(){
        var w=harness.seedWorld("request-correction-"+UUID.randomUUID());harness.loginAs(w.superAdminUserId());
        var view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"request-preview-"+w.goodsD(),
            List.of(new PreviewItem("STOCK",null,w.goodsD(),null,w.unitId(),"exact-request-"+w.goodsD(),"真实计划来源数量修正",BusinessTime.today(),new BigDecimal("1.2345")))));
        var material=view.flatMaterials().stream().filter(row->row.goodsId().equals(w.goodsD())&&row.actionable()).findFirst().orElseThrow();
        view=analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"request-route-"+w.goodsD(),List.of(new RouteDecision(material.materialLineId(),material.actionGroupKey(),"BUY",null))));
        view=commands.notifySupply(view.analysisId(),new NotifyRequest(view.version(),view.fingerprint(),"request-notify-"+w.goodsD(),"BUY",List.of(material.materialLineId()),List.of(),List.of(),true));
        UUID item=db.queryForObject("SELECT allocation.external_item_id FROM preplan_supply_action_allocations allocation WHERE analysis_id=?",UUID.class,view.analysisId());
        UUID request=db.queryForObject("SELECT request_id FROM purchase_request_items WHERE id=?",UUID.class,item);
        UUID reviewer=harness.createUserWithPerms(w,"request-corrector-"+item,"purchase_request:view","purchase_order:decompose");harness.loginAs(reviewer);
        return new Source(w,request,item,reviewer,view.analysisId());
    }
    long version(Source s){return db.queryForObject("SELECT row_version FROM purchase_request_items WHERE id=?",Long.class,s.item());}
    BigDecimal quantity(Source s){return db.queryForObject("SELECT qty FROM purchase_request_items WHERE id=?",BigDecimal.class,s.item());}
    int proofs(Source s){return db.queryForObject("SELECT COUNT(*) FROM purchase_request_qty_revisions WHERE request_item_id=?",Integer.class,s.item());}
}
