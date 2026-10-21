package com.uten.imp.businesschain;

import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.CancelRequest;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewItem;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.util.List;
import java.util.UUID;
import java.math.BigDecimal;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static com.uten.imp.businesschain.AggregateMaterialOrderEndToEndTest.amount;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class AggregateMaterialWithdrawalEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    AggregateMaterialOrderEndToEndTest h;
    @BeforeEach void before(){h=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(h);h.before();}
    @AfterEach void after(){h.after();}

    @ParameterizedTest @ValueSource(strings={"BUY","SUBCONTRACT"})
    void sharedParentPreservesSeparatelyOrderedPurchaseAndSubcontractChildren(String route) {
        var c=h.createWithChild("5",1);
        var parent=h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.common(),"MAKE","5",false)))).batches().getFirst();
        if("SUBCONTRACT".equals(route))h.receive(c,c.material(),"10");
        var routeView=h.analyses.detail(c.analysis());
        UUID material=routeView.flatMaterials().stream().filter(row->row.analysisLineId().equals(parent.anchorAnalysisItemId())&&row.goodsId().equals(c.child())).findFirst().orElseThrow().materialLineId();
        h.analyses.saveRoutes(c.analysis(),new com.uten.imp.features.production.analysis.MaterialAnalysisContracts.RouteRequest(routeView.version(),routeView.fingerprint(),"external-child-route-"+UUID.randomUUID(),
                List.of(new com.uten.imp.features.production.analysis.MaterialAnalysisContracts.RouteDecision(material,null,route,"独立子件外部供给"))));
        var input=new com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.GroupInput(c.child().toString(),List.of(material),route,new BigDecimal("5"),false,null,null,null,null,null,null,null,BigDecimal.ZERO);
        var child=h.writer.submit(c.analysis(),h.command(c,List.of(input))).batches().getFirst();
        UUID parentAction=h.db.queryForObject("SELECT action_id FROM preplan_aggregate_batches WHERE id=?",UUID.class,parent.batchId());
        UUID childAction=h.db.queryForObject("SELECT action_id FROM preplan_aggregate_batches WHERE id=?",UUID.class,child.batchId());
        var before=h.analyses.detail(c.analysis());
        var after=h.writer.cancel(c.analysis(),parentAction,new CancelRequest(before.version(),before.fingerprint(),"external-child-parent-cancel-"+UUID.randomUUID(),"保留独立外部供给单据"));
        amount("0",h.db.queryForObject("SELECT requested_qty FROM production_material_analysis_items WHERE id=?",BigDecimal.class,parent.anchorAnalysisItemId()));
        assertEquals("CREATED",h.db.queryForObject("SELECT status FROM preplan_supply_actions WHERE id=?",String.class,childAction));
        assertEquals(child.documentId(),h.db.queryForObject("SELECT external_document_id FROM preplan_supply_actions WHERE id=?",UUID.class,childAction));
        String sql="BUY".equals(route)?"SELECT qty FROM purchase_request_items WHERE request_id=? AND NOT is_deleted":"SELECT qty FROM subcontract_application_items WHERE application_id=? AND NOT is_deleted";
        amount("5",h.db.queryForObject(sql,BigDecimal.class,child.documentId()));
        h.writer.cancel(c.analysis(),childAction,new CancelRequest(after.version(),after.fingerprint(),"external-child-cancel-"+UUID.randomUUID(),"随后独立撤回外部申请"));
        assertEquals("CANCELLED",h.db.queryForObject("SELECT status FROM preplan_supply_actions WHERE id=?",String.class,childAction));
    }

    @Test void sharedParentAlsoPreservesTheExactSourceOfAnOrdinaryChildPlan() {
        var c=h.createWithChild("5",1);
        var parent=h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.common(),"MAKE","5",false)))).batches().getFirst();
        var before=h.analyses.detail(c.analysis());
        UUID material=before.flatMaterials().stream().filter(row->row.analysisLineId().equals(parent.anchorAnalysisItemId())&&row.goodsId().equals(c.child())).findFirst().orElseThrow().materialLineId();
        var issued=h.ordinary.issueWorkshopPlans(c.analysis(),new com.uten.imp.features.production.analysis.MaterialAnalysisContracts.IssueWorkshopPlansRequest(
                before.version(),before.fingerprint(),"ordinary-child-before-parent-"+UUID.randomUUID(),c.world().warehouseId(),com.uten.imp.common.time.BusinessTime.today(),null,true,
                List.of(new com.uten.imp.features.production.analysis.MaterialAnalysisContracts.IssueWorkshopPlansRequest.IssuePlanLine(material,null,new BigDecimal("5"),null,null,c.workshop(),null,c.worker(),null,null,false,BigDecimal.ZERO))));
        UUID childPlan=issued.plans().getFirst().planId();
        UUID childSource=h.db.queryForObject("SELECT material_analysis_item_id FROM production_plans WHERE id=?",UUID.class,childPlan);
        assertEquals("MAKE_COMPONENT",h.db.queryForObject("SELECT source_type FROM production_material_analysis_items WHERE id=?",String.class,childSource));
        UUID action=h.db.queryForObject("SELECT action_id FROM preplan_aggregate_batches WHERE id=?",UUID.class,parent.batchId());
        var current=h.analyses.detail(c.analysis());
        var after=h.writer.cancel(c.analysis(),action,new CancelRequest(current.version(),current.fingerprint(),"ordinary-child-parent-cancel-"+UUID.randomUUID(),"保留已下达普通子计划"));
        amount("0",h.db.queryForObject("SELECT requested_qty FROM production_material_analysis_items WHERE id=?",BigDecimal.class,parent.anchorAnalysisItemId()));
        assertEquals(1,h.db.queryForObject("SELECT status FROM production_plans WHERE id=?",Integer.class,childPlan));
        assertEquals(material,h.db.queryForObject("SELECT parent_analysis_material_id FROM production_material_analysis_items WHERE id=? AND NOT is_deleted",UUID.class,childSource));
        amount("5",h.db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,childPlan));
        var withdrawn=beans.getBean(com.uten.imp.features.production.analysis.MaterialAnalysisPlanWithdrawalService.class).withdraw(c.analysis(),childPlan,
                new com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PlanWithdrawalRequest(after.version(),after.fingerprint(),"ordinary-child-withdraw-"+UUID.randomUUID(),"随后撤回普通子计划"));
        assertEquals(-1,h.db.queryForObject("SELECT status FROM production_plans WHERE id=?",Integer.class,childPlan));
        amount("0",h.db.queryForObject("SELECT requested_qty FROM production_material_analysis_items WHERE id=?",BigDecimal.class,parent.anchorAnalysisItemId()));
        amount("5",withdrawn.products().stream().filter(product->product.analysisLineId().equals(childSource)).findFirst().orElseThrow().remainingQty());
    }

    @Test void sharedParentCanWithdrawBeforeExecutionAfterItsDescendantsWereOrdered() {
        var c=h.createWithChild("5000",1);
        var parent=h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.common(),"MAKE","5000",false)))).batches().getFirst();
        var child=h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.child(),"MAKE","5000",false)))).batches().getFirst();
        var leaf=h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.material(),"BUY","10000",false)))).batches().getFirst();
        UUID action=h.db.queryForObject("SELECT action_id FROM preplan_aggregate_batches WHERE id=?",UUID.class,parent.batchId());
        var view=h.analyses.detail(c.analysis());
        var request=new CancelRequest(view.version(),view.fingerprint(),"nested-parent-cancel-"+UUID.randomUUID(),"撤回未开工的共享父计划");
        var after=assertDoesNotThrow(()->h.writer.cancel(c.analysis(),action,request));
        h.writer.cancel(c.analysis(),action,request);
        assertEquals("CANCELLED",h.db.queryForObject("SELECT status FROM preplan_supply_actions WHERE id=?",String.class,action));
        assertEquals(-1,h.db.queryForObject("SELECT status FROM production_plans WHERE id=?",Integer.class,parent.planId()));
        assertEquals(1,h.db.queryForObject("SELECT status FROM production_plans WHERE id=?",Integer.class,child.planId()));
        assertEquals(1,h.count("SELECT count(*) FROM purchase_requests WHERE id=? AND NOT is_deleted",leaf.documentId()));
        assertFalse(h.db.queryForObject("SELECT is_deleted FROM production_material_analysis_items WHERE id=?",Boolean.class,parent.anchorAnalysisItemId()));
        amount("0",h.db.queryForObject("SELECT requested_qty FROM production_material_analysis_items WHERE id=?",BigDecimal.class,parent.anchorAnalysisItemId()));
        amount("0",h.db.queryForObject("SELECT submitted_qty+approved_qty FROM production_material_analysis_items WHERE id=?",BigDecimal.class,parent.anchorAnalysisItemId()));
        var refreshed=h.analyses.preview(new PreviewRequest(c.analysis(),after.version(),after.fingerprint(),c.world().warehouseId(),"withdrawn-parent-refresh-"+UUID.randomUUID(),
                after.products().stream().filter(product->"SALES_ORDER_ITEM".equals(product.sourceType()))
                        .map(product->new PreviewItem("SALES_ORDER_ITEM",product.salesOrderItemId(),null,null,null,null,null,product.deliveryDate(),product.requestedQty())).toList()));
        amount("0",h.db.queryForObject("SELECT requested_qty FROM production_material_analysis_items WHERE id=?",BigDecimal.class,parent.anchorAnalysisItemId()));
        amount("5000",h.db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,child.planId()));
        amount("10000",h.db.queryForObject("SELECT qty FROM purchase_request_items WHERE request_id=? AND NOT is_deleted",BigDecimal.class,leaf.documentId()));
        assertEquals(1,h.count("SELECT count(*) FROM preplan_aggregate_batch_events WHERE batch_id=? AND event_type='CANCEL'",parent.batchId()));
        UUID childAction=h.db.queryForObject("SELECT action_id FROM preplan_aggregate_batches WHERE id=?",UUID.class,child.batchId());
        var childCancelled=h.writer.cancel(c.analysis(),childAction,new CancelRequest(refreshed.version(),refreshed.fingerprint(),"nested-child-cancel-"+UUID.randomUUID(),"继续撤回独立子计划"));
        UUID leafAction=h.db.queryForObject("SELECT action_id FROM preplan_aggregate_batches WHERE id=?",UUID.class,leaf.batchId());
        h.writer.cancel(c.analysis(),leafAction,new CancelRequest(childCancelled.version(),childCancelled.fingerprint(),"nested-leaf-cancel-"+UUID.randomUUID(),"继续撤回独立采购"));
        assertEquals("CANCELLED",h.db.queryForObject("SELECT status FROM preplan_supply_actions WHERE id=?",String.class,childAction));
        assertEquals("CANCELLED",h.db.queryForObject("SELECT status FROM preplan_supply_actions WHERE id=?",String.class,leafAction));
    }
}
