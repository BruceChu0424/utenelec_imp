package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.*;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest;
import com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageLine;
import com.uten.imp.features.production.execution.*;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.businesschain.AggregateMaterialOrderEndToEndTest.amount;
import static org.junit.jupiter.api.Assertions.*;

/** Real source identities, cancelled parent, surviving child, and physical receipts. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class AggregateRetainedResponsibilityEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    AggregateMaterialOrderEndToEndTest h;
    @BeforeEach void before(){h=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(h);h.before();}
    @AfterEach void after(){h.after();}

    @Test void originalPrivatePromiseSurvivesCancellationAndNewParentWithoutDuplicatingSupply() {
        var c=h.createWithChild("100",2);var initial=h.analyses.detail(c.analysis());
        Map<UUID,BigDecimal> common=originals(initial,c.common()),children=originals(initial,c.child());
        var parent=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,c.common(),common)))).batches().getFirst();
        var child=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,c.child(),children)))).batches().getFirst();
        cancel(c,parent,"retain-original-child");
        var retained=h.analyses.detail(c.analysis());
        assertOriginalCovered(retained,children.keySet());
        amount("200",h.db.queryForObject("SELECT SUM(current_qty) FROM fn_preplan_aggregate_retained_private_sources(?)",BigDecimal.class,c.analysis()));
        var replacement=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,c.common(),common)))).batches().getFirst();
        assertNotEquals(parent.batchId(),replacement.batchId());
        var rebuilt=h.analyses.detail(c.analysis());assertOriginalCovered(rebuilt,children.keySet());
        var canonical=rebuilt.flatMaterials().stream().filter(row->row.analysisLineId().equals(replacement.anchorAnalysisItemId())&&row.goodsId().equals(c.child())).findFirst().orElseThrow();
        amount("0",canonical.planningUncoveredQty());
        amount("200",h.db.queryForObject("SELECT fn_preplan_action_admitted_qty(action_id) FROM preplan_aggregate_batches WHERE id=?",BigDecimal.class,child.batchId()));
        amount("0",h.db.queryForObject("SELECT SUM(fn_preplan_aggregate_alias_qty(id)) FROM preplan_aggregate_material_aliases WHERE batch_id=?",BigDecimal.class,parent.batchId()));
    }

    @Test void unevenSourcesReceiveFortyEightyThenTwentyFortyAcrossParentRebuild() {
        var c=h.createWithChild("200",2);var initial=h.analyses.detail(c.analysis());
        var sources=initial.products().stream().filter(product->"SALES_ORDER_ITEM".equals(product.sourceType())).toList();
        initial=h.analyses.preview(new PreviewRequest(c.analysis(),initial.version(),initial.fingerprint(),c.world().warehouseId(),"uneven-sources-"+UUID.randomUUID(),List.of(
                new PreviewItem("SALES_ORDER_ITEM",sources.get(0).salesOrderItemId(),null,null,null,null,null,BusinessTime.today().plusDays(10),new BigDecimal("100")),
                new PreviewItem("SALES_ORDER_ITEM",sources.get(1).salesOrderItemId(),null,null,null,null,null,BusinessTime.today().plusDays(10),new BigDecimal("200")))));
        Map<UUID,BigDecimal> common=originals(initial,c.common()),children=originals(initial,c.child());
        var parent=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,c.common(),common)))).batches().getFirst();
        var child=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,c.child(),children)))).batches().getFirst();
        cancel(c,parent,"uneven-parent-cancel");
        start(c,child,"600");receive(c,child,"120","240");
        assertReceipts(c,child,children,"0.4");
        var replacement=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,c.common(),common)))).batches().getFirst();
        receive(c,child,"60","120");assertReceipts(c,child,children,"0.6");
        UUID canonical=h.analyses.detail(c.analysis()).flatMaterials().stream().filter(row->row.analysisLineId().equals(replacement.anchorAnalysisItemId())&&row.goodsId().equals(c.child())).findFirst().orElseThrow().materialLineId();
        // Arrival can already formalize the ready portion of this exact task.
        amount("180",h.db.queryForObject("SELECT fn_preplan_aggregate_target_committed_qty(?)",BigDecimal.class,canonical));
        amount("120",h.db.queryForObject("SELECT SUM(pending_qty) FROM fn_preplan_aggregate_retained_private_sources(?)",BigDecimal.class,c.analysis()));
        amount("0",h.db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM preplan_analysis_stock_exact_pegs WHERE supply_action_allocation_id IN(SELECT id FROM preplan_supply_action_allocations WHERE action_id=(SELECT action_id FROM preplan_aggregate_batches WHERE id=?)) AND origin_analysis_material_id NOT IN(SELECT original_material_id FROM fn_preplan_aggregate_recorded_private_sources((SELECT analysis_id FROM preplan_aggregate_batches WHERE id=?)))",BigDecimal.class,child.batchId(),child.batchId()));
    }

    @Test void receiptOnOldCanonicalBlocksWholeParentWithdrawalBeforeAnyPlanChanges() {
        var c=h.createWithChild("100",1);var initial=h.analyses.detail(c.analysis());
        var parent=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,c.common(),originals(initial,c.common()))))).batches().getFirst();
        var child=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,c.child(),originals(initial,c.child()))))).batches().getFirst();
        start(c,child,"200");receive(c,child,"40","80");
        long receipts=h.db.queryForObject("SELECT COUNT(*) FROM preplan_analysis_stock_exact_pegs WHERE supply_action_allocation_id IN(SELECT id FROM preplan_supply_action_allocations WHERE action_id=(SELECT action_id FROM preplan_aggregate_batches WHERE id=?))",Long.class,child.batchId());
        var error=assertThrows(ApiException.class,()->cancel(c,parent,"received-child-parent-cancel"));
        assertEquals(com.uten.imp.common.web.ErrorCode.CONFLICT,error.getCode());
        assertTrue(error.getMessage().contains("实收"));
        assertEquals(1,h.db.queryForObject("SELECT status FROM production_plans WHERE id=?",Integer.class,parent.planId()));
        assertEquals(0,h.db.queryForObject("SELECT COUNT(*) FROM preplan_aggregate_batch_events WHERE batch_id=? AND event_type='CANCEL'",Integer.class,parent.batchId()));
        assertEquals(receipts,h.db.queryForObject("SELECT COUNT(*) FROM preplan_analysis_stock_exact_pegs WHERE supply_action_allocation_id IN(SELECT id FROM preplan_supply_action_allocations WHERE action_id=(SELECT action_id FROM preplan_aggregate_batches WHERE id=?))",Long.class,child.batchId()));
    }

    @Test void ancestorQualifiedEightyLeavesOnlyTwentyNewPrivateOutputAndNoGhostFuture() {
        var c=h.createWithChild("100",1);var initial=h.analyses.detail(c.analysis());
        var common=originals(initial,c.common());var children=originals(initial,c.child());
        var parent=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,c.common(),common)))).batches().getFirst();
        var child=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,c.child(),children)))).batches().getFirst();
        cancel(c,parent,"ancestor-parent-cancel");
        UUID donorProduct=UUID.randomUUID();
        h.fixture.insertGoods(donorProduct,"RET-DONOR-"+donorProduct,"祖先最终件的独立来源","自制",c.world().unitId(),c.world().unitLegacy());
        h.fixture.insertBom(donorProduct,c.common(),"1");
        var donor=h.analyses.preview(new PreviewRequest(null,null,null,c.world().warehouseId(),"ancestor-donor-"+UUID.randomUUID(),
                List.of(new PreviewItem("OTHER",null,donorProduct,null,c.world().unitId(),"祖先最终件独立采购","核对真实最终件对下层责任的影响",BusinessTime.today().plusDays(10),new BigDecimal("80")))));
        UUID donorMaterial=donor.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).findFirst().orElseThrow().materialLineId();
        donor=h.analyses.saveRoutes(donor.analysisId(),new RouteRequest(donor.version(),donor.fingerprint(),"ancestor-donor-route-"+UUID.randomUUID(),List.of(new RouteDecision(donorMaterial,null,"BUY","独立供给最终父件"))));
        h.ordinary.notifySupply(donor.analysisId(),new NotifyRequest(donor.version(),donor.fingerprint(),"ancestor-final-eighty-"+UUID.randomUUID(),"BUY",List.of(donorMaterial),List.of(),
                List.of(new SupplyQuantityInput(null,donorMaterial,new BigDecimal("80"),BigDecimal.ZERO))));
        UUID orderItem=org.springframework.test.util.ReflectionTestUtils.invokeMethod(h.fixture,"approveExistingAnalysisPurchase",c.world(),donor.analysisId(),c.common());
        org.springframework.test.util.ReflectionTestUtils.invokeMethod(h.fixture,"receiveAndPassPurchase",c.world(),orderItem,c.common(),new BigDecimal("80"),"ancestor-eighty-"+UUID.randomUUID());
        h.fixture.loginAs(c.world().superAdminUserId());
        donor=h.analyses.detail(donor.analysisId());var view=h.analyses.detail(c.analysis());UUID commonMaterial=common.keySet().iterator().next();
        view=h.analyses.saveRoutes(c.analysis(),new RouteRequest(view.version(),view.fingerprint(),"ancestor-target-make-"+UUID.randomUUID(),
                List.of(new RouteDecision(commonMaterial,null,"MAKE","保留余量的真实制造责任"))));
        beans.getBean(com.uten.imp.features.production.analysis.MaterialStockReallocationService.class).createReturningTarget(donor.analysisId(),
                new CrossReallocationRequest(donor.version(),donor.fingerprint(),donorMaterial,c.analysis(),view.version(),view.fingerprint(),commonMaterial,new BigDecimal("80"),"用真实合格最终件覆盖祖先，余量仍自制","ancestor-cross-eighty-"+UUID.randomUUID()));
        assertEquals("MAKE",h.db.queryForObject("SELECT confirmed_route FROM production_material_analysis_materials WHERE id=?",String.class,commonMaterial));
        amount("20",h.db.queryForObject("SELECT SUM(current_qty) FROM fn_preplan_aggregate_retained_private_sources(?)",BigDecimal.class,c.analysis()));
        start(c,child,"200");receive(c,child,"100","200");
        amount("20",h.db.queryForObject("SELECT fn_preplan_action_admitted_qty(action_id) FROM preplan_aggregate_batches WHERE id=?",BigDecimal.class,child.batchId()));
        amount("20",h.db.queryForObject("SELECT fn_preplan_action_received_qty(action_id) FROM preplan_aggregate_batches WHERE id=?",BigDecimal.class,child.batchId()));
        amount("0",h.db.queryForObject("SELECT SUM(pending_qty) FROM fn_preplan_aggregate_retained_private_sources(?)",BigDecimal.class,c.analysis()));
        assertEquals("DONE",h.db.queryForObject("SELECT action.status FROM preplan_supply_actions action JOIN preplan_aggregate_batches batch ON batch.action_id=action.id WHERE batch.id=?",String.class,child.batchId()));
    }

    @Test void repeatedTenThousandthReceiptsUseTheSameCumulativeOriginalBoundaries() {
        var c=h.createWithChild("2",2);var initial=h.analyses.detail(c.analysis());
        var sales=initial.products().stream().filter(product->"SALES_ORDER_ITEM".equals(product.sourceType())).toList();
        initial=h.analyses.preview(new PreviewRequest(c.analysis(),initial.version(),initial.fingerprint(),c.world().warehouseId(),"quantum-sources-"+UUID.randomUUID(),List.of(
                new PreviewItem("SALES_ORDER_ITEM",sales.get(0).salesOrderItemId(),null,null,null,null,null,BusinessTime.today().plusDays(10),BigDecimal.ONE),
                new PreviewItem("SALES_ORDER_ITEM",sales.get(1).salesOrderItemId(),null,null,null,null,null,BusinessTime.today().plusDays(10),new BigDecimal("2")))));
        var common=originals(initial,c.common());var children=originals(initial,c.child());
        var parent=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,c.common(),common)))).batches().getFirst();
        var child=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,c.child(),children)))).batches().getFirst();cancel(c,parent,"quantum-parent-cancel");
        start(c,child,"6");for(int index=0;index<3;index++)receive(c,child,"0.0001","0.0002");
        assertReceipts(c,child,children,"0.0001");
        amount("0.0003",h.db.queryForObject("SELECT SUM(received_qty) FROM fn_preplan_aggregate_retained_private_sources(?)",BigDecimal.class,c.analysis()));
        amount("2.9997",h.db.queryForObject("SELECT SUM(pending_qty) FROM fn_preplan_aggregate_retained_private_sources(?)",BigDecimal.class,c.analysis()));
    }

    @Test void historicalParentCancellationWithCanonicalReceiptRemainsReadableAndBlocksNewPlanning() {
        var c=h.createWithChild("100",1);var initial=h.analyses.detail(c.analysis());var children=originals(initial,c.child());
        var parent=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,c.common(),originals(initial,c.common()))))).batches().getFirst();
        var child=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,c.child(),children)))).batches().getFirst();
        start(c,child,"200");receive(c,child,"40","80");
        // Reproduce the pre-V895 cancellation contract in this Testcontainer.
        // Restore the authority in the same transaction; no company DB is used.
        new org.springframework.transaction.support.TransactionTemplate(beans.getBean(org.springframework.transaction.PlatformTransactionManager.class)).executeWithoutResult(status->{
            String definition=h.db.queryForObject("SELECT pg_get_functiondef('fn_preplan_material_has_qualified_receipt(uuid)'::regprocedure)",String.class);
            h.db.execute("CREATE OR REPLACE FUNCTION fn_preplan_material_has_qualified_receipt(p_material UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS 'SELECT FALSE'");
            try{cancel(c,parent,"historical-before-v895");}finally{h.db.execute(definition);}
        });
        var readable=assertDoesNotThrow(()->h.analyses.detail(c.analysis()));
        UUID originalSource=readable.flatMaterials().stream().filter(row->children.containsKey(row.materialLineId())).findFirst().orElseThrow().analysisLineId();
        assertTrue(readable.planningBlockedReasons().get(originalSource).contains("实收"));
        amount("0",h.db.queryForObject("SELECT SUM(current_qty) FROM fn_preplan_aggregate_retained_private_sources(?)",BigDecimal.class,c.analysis()));
        amount("0",h.db.queryForObject("SELECT SUM(pending_qty) FROM fn_preplan_aggregate_retained_private_sources(?)",BigDecimal.class,c.analysis()));
        assertTrue(assertThrows(ApiException.class,()->h.writer.submit(c.analysis(),h.command(c,List.of(input(c,c.child(),children))))).getMessage().contains("实收"));
        amount("40",h.db.queryForObject("SELECT fn_preplan_action_received_qty(action_id) FROM preplan_aggregate_batches WHERE id=?",BigDecimal.class,child.batchId()));
    }

    @Test void partialOriginalProofDoesNotClaimOrBlockTheOtherParentsSource() {
        var c=h.createWithChild("100",2);var initial=h.analyses.detail(c.analysis());
        var children=originals(initial,c.child());var ids=children.keySet().stream().sorted().toList();
        var parent=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,c.common(),originals(initial,c.common()))))).batches().getFirst();
        var child=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,c.child(),Map.of(ids.getFirst(),new BigDecimal("100")))))).batches().getFirst();
        var cancelled=cancel(c,parent,"partial-proof-parent-cancel");
        assertTrue(cancelled.planningBlockedReasons().isEmpty());
        amount("100",h.db.queryForObject("SELECT SUM(current_qty) FROM fn_preplan_aggregate_retained_private_sources(?)",BigDecimal.class,c.analysis()));
        amount("0",h.db.queryForObject("SELECT COALESCE(SUM(recorded_qty),0) FROM fn_preplan_aggregate_recorded_private_sources(?) WHERE supply_batch_id=? AND original_material_id=?",BigDecimal.class,c.analysis(),child.batchId(),ids.get(1)));
        var other=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,c.child(),Map.of(ids.get(1),new BigDecimal("100"))))));
        assertFalse(other.batches().isEmpty());
        assertOriginalCovered(h.analyses.detail(c.analysis()),new HashSet<>(ids));
    }

    @Test void pendingFinanceRejectsWholeRetainedReceiptWithoutMakingPrivateOutputPublic() {
        var c=h.createWithChild("100",1);var initial=h.analyses.detail(c.analysis());
        var parent=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,c.common(),originals(initial,c.common()))))).batches().getFirst();
        var child=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,c.child(),originals(initial,c.child()))))).batches().getFirst();
        cancel(c,parent,"finance-parent-cancel");start(c,child,"200");UUID report=report(c,child,"40","80");
        UUID inbound=h.db.queryForObject("SELECT id FROM stock_documents WHERE source_daily_report_id=? AND doc_type='FINISHED_IN' AND NOT is_deleted",UUID.class,report);
        var product=initial.products().stream().filter(row->"SALES_ORDER_ITEM".equals(row.sourceType())).findFirst().orElseThrow();
        UUID order=h.db.queryForObject("SELECT order_id FROM sales_order_items WHERE id=?",UUID.class,product.salesOrderItemId());
        var line=new com.uten.imp.features.sales.order.dto.OrderChangeQtyRequest.Line();line.setOrderItemId(product.salesOrderItemId());line.setNewQty(new BigDecimal("120"));
        var change=new com.uten.imp.features.sales.order.dto.OrderChangeQtyRequest();change.setItems(List.of(line));
        beans.getBean(com.uten.imp.features.sales.order.SalesOrderService.class).changeQty(order,change);
        var denied=assertThrows(ApiException.class,()->h.fixture.confirmFinishedInboundFully(inbound));
        assertEquals(com.uten.imp.common.web.ErrorCode.CONFLICT,denied.getCode());
        assertEquals(0,h.db.queryForObject("SELECT status FROM stock_documents WHERE id=?",Integer.class,inbound));
        amount("0",h.db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",BigDecimal.class,c.child()));
        amount("100",h.db.queryForObject("SELECT fn_preplan_action_admitted_qty(action_id) FROM preplan_aggregate_batches WHERE id=?",BigDecimal.class,child.batchId()));
        var claim=beans.getBean(com.uten.imp.features.common.taskclaim.TaskClaimService.class).claim("SALES_ORDER_FINANCE_CONFIRM",order.toString());
        Long revision=h.db.queryForObject("SELECT finance_review_revision FROM sales_orders WHERE id=?",Long.class,order);
        beans.getBean(com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService.class).confirm(order,
                new com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,revision,claim.claimId()));
        h.fixture.confirmFinishedInboundFully(inbound);
        amount("40",h.db.queryForObject("SELECT SUM(received_qty) FROM fn_preplan_aggregate_retained_private_sources(?)",BigDecimal.class,c.analysis()));
    }

    @Test void retainedReceiptReversalRestoresTheSamePrivatePendingWithoutChangingOrigins() {
        var c=h.createWithChild("100",1);var initial=h.analyses.detail(c.analysis());
        var parent=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,c.common(),originals(initial,c.common()))))).batches().getFirst();
        var child=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,c.child(),originals(initial,c.child()))))).batches().getFirst();
        cancel(c,parent,"reverse-parent-cancel");start(c,child,"200");receive(c,child,"40","80");
        UUID inbound=h.db.queryForObject("SELECT exact.source_stock_document_id FROM preplan_analysis_stock_exact_pegs exact JOIN preplan_supply_action_allocations allocation ON allocation.id=exact.supply_action_allocation_id JOIN preplan_aggregate_batches batch ON batch.action_id=allocation.action_id WHERE batch.id=?",UUID.class,child.batchId());
        long origins=h.db.queryForObject("SELECT COUNT(*) FROM preplan_analysis_stock_exact_pegs WHERE source_stock_document_id=?",Long.class,inbound);
        InventoryValueWorkTestSupport.drain(beans.getBean(com.uten.imp.features.stock.valuation.InventoryValueWorkService.class),h.db,List.of(c.child(),c.material()));
        beans.getBean(StockDocService.class).reverseFinishedInbound(inbound);
        amount("0",h.db.queryForObject("SELECT SUM(received_qty) FROM fn_preplan_aggregate_retained_private_sources(?)",BigDecimal.class,c.analysis()));
        amount("100",h.db.queryForObject("SELECT SUM(pending_qty) FROM fn_preplan_aggregate_retained_private_sources(?)",BigDecimal.class,c.analysis()));
        amount("0",h.db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",BigDecimal.class,c.child()));
        assertEquals(origins,h.db.queryForObject("SELECT COUNT(*) FROM preplan_analysis_stock_exact_pegs WHERE source_stock_document_id=?",Long.class,inbound));
    }

    private static Map<UUID,BigDecimal> originals(AnalysisView view,UUID goods) {
        Set<UUID> roots=new HashSet<>();view.products().stream().filter(product->"SALES_ORDER_ITEM".equals(product.sourceType())).forEach(product->roots.add(product.analysisLineId()));
        Map<UUID,BigDecimal> result=new LinkedHashMap<>();view.flatMaterials().stream().filter(row->roots.contains(row.analysisLineId())&&row.goodsId().equals(goods)).forEach(row->result.put(row.materialLineId(),row.sourceRequiredQty()));
        assertFalse(result.isEmpty());return result;
    }
    private GroupInput input(AggregateMaterialOrderEndToEndTest.Case c,UUID goods,Map<UUID,BigDecimal> shares) {
        return new GroupInput(goods.toString(),new ArrayList<>(shares.keySet()),"MAKE",shares.values().stream().reduce(BigDecimal.ZERO,BigDecimal::add),false,
                c.workshop(),c.worker(),null,null,null,null,BigDecimal.ZERO,BigDecimal.ZERO,shares);
    }
    private AnalysisView cancel(AggregateMaterialOrderEndToEndTest.Case c,BatchResult parent,String key) {
        UUID action=h.db.queryForObject("SELECT action_id FROM preplan_aggregate_batches WHERE id=?",UUID.class,parent.batchId());var view=h.analyses.detail(c.analysis());
        return h.writer.cancel(c.analysis(),action,new CancelRequest(view.version(),view.fingerprint(),key+"-"+UUID.randomUUID(),"核对独立子件责任"));
    }
    private static void assertOriginalCovered(AnalysisView view,Set<UUID> originals) {
        var rows=view.flatMaterials().stream().filter(row->originals.contains(row.materialLineId())).toList();
        assertEquals(originals.size(),rows.size());rows.forEach(row->amount("0",row.planningUncoveredQty()));
    }
    private void assertReceipts(AggregateMaterialOrderEndToEndTest.Case c,BatchResult child,Map<UUID,BigDecimal> shares,String ratio) {
        for(var share:shares.entrySet())amount(share.getValue().multiply(new BigDecimal(ratio)).toPlainString(),h.db.queryForObject("SELECT COALESCE(SUM(exact.qty),0) FROM preplan_analysis_stock_exact_pegs exact JOIN preplan_supply_action_allocations allocation ON allocation.id=exact.supply_action_allocation_id JOIN preplan_aggregate_batches batch ON batch.action_id=allocation.action_id WHERE batch.id=? AND exact.origin_analysis_material_id=?",BigDecimal.class,child.batchId(),share.getKey()));
        h.fixture.loginAs(c.world().superAdminUserId());
    }
    private void start(AggregateMaterialOrderEndToEndTest.Case c,BatchResult child,String leaf) {
        h.receive(c,c.material(),leaf);
        var view=h.analyses.detail(c.analysis());
        h.analyses.preview(new PreviewRequest(c.analysis(),view.version(),view.fingerprint(),c.world().warehouseId(),"retained-receipt-refresh-"+UUID.randomUUID(),
                view.products().stream().filter(product->"SALES_ORDER_ITEM".equals(product.sourceType())).map(product->new PreviewItem("SALES_ORDER_ITEM",product.salesOrderItemId(),null,null,null,null,null,product.deliveryDate(),product.requestedQty())).toList()));
        UUID segment=segment(child);var draws=beans.getBean(ProductionDrawRequestService.class);var item=new ProductionDrawRequest.Item(segment,version(segment));
        var preview=draws.preview(new ProductionDrawRequest.PreviewRequest(List.of(item)));
        draws.submit(new ProductionDrawRequest.SubmitRequest(List.of(item),"retain-draw-"+segment,preview.fingerprint()));
        var stock=beans.getBean(StockDocService.class);
        for(UUID document:preview.lines().stream().map(ProductionDrawRequest.Line::drawId).distinct().toList()) {
            var issue=new StockDocIssueRequest();issue.setIdempotencyKey("retain-issue-"+document);issue.setLines(preview.lines().stream().filter(row->document.equals(row.drawId())).map(row->{var line=new StockDocIssueRequest.Line();line.setItemId(row.drawItemId());line.setQty(row.qty());return line;}).toList());stock.approveAndIssue(document,issue);
        }
        beans.getBean(ProductionExecutionSegmentService.class).start(child.planId(),segment,new SegmentTransitionRequest(version(segment),"retain-start-"+segment));
    }
    private void receive(AggregateMaterialOrderEndToEndTest.Case c,BatchResult child,String output,String used) {
        UUID report=report(c,child,output,used);
        for(UUID document:h.db.queryForList("SELECT id FROM stock_documents WHERE doc_type='FINISHED_IN' AND source_daily_report_id=? AND NOT is_deleted",UUID.class,report))h.fixture.confirmFinishedInboundFully(document);
        h.fixture.loginAs(c.world().superAdminUserId());
    }
    private UUID report(AggregateMaterialOrderEndToEndTest.Case c,BatchResult child,String output,String used) {
        UUID segment=segment(child),planItem=h.db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",UUID.class,child.planId());
        var usage=new DailyReportMaterialUsageLine();usage.setDemandId(h.db.queryForObject("SELECT id FROM production_material_demands WHERE execution_segment_id=? AND NOT is_deleted",UUID.class,segment));usage.setQtyBase(new BigDecimal(used));
        UUID report=h.fixture.reportAndApproveExecutionSegment(c.world(),planItem,null,c.child(),segment,null,output,false,"0",null,null,List.of(usage));
        h.fixture.loginAs(c.world().superAdminUserId());
        return report;
    }
    private UUID segment(BatchResult child){return h.db.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted",UUID.class,child.planId());}
    private long version(UUID segment){return h.db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,segment);}
}
