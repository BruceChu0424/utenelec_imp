package com.uten.imp.businesschain;

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

/** A single source's gross curve cannot replace two independently frozen batch curves. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class AggregateRetainedBatchCurveEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    AggregateMaterialOrderEndToEndTest h;
    final Map<UUID,UUID> selectedSegments=new HashMap<>();
    @BeforeEach void before(){h=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(h);h.before();}
    @AfterEach void after(){h.after();}

    @Test void independentlyFrozenFiftyFiftyFixedBatchesCannotBeWithdrawnAsOneGrossHundredCurve() {
        var c=h.createWithChild("100",1);
        h.db.update("UPDATE goods_bom_items SET qty=10,consumption_basis='FIXED_BATCH',basis_output_qty=100 WHERE goods_id=? AND component_goods_id=?",c.common(),c.child());
        var initial=refresh(c);
        UUID originalParent=original(initial,c.common()),originalChild=original(initial,c.child());
        amount("10",initial.flatMaterials().stream().filter(row->row.materialLineId().equals(originalChild)).findFirst().orElseThrow().sourceRequiredQty());
        var first=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,originalParent,c.common(),"50","0")))).batches().getFirst();
        var splitDemand=h.analyses.detail(c.analysis());
        amount("20",splitDemand.flatMaterials().stream().filter(row->row.goodsId().equals(c.child()))
                .map(MaterialView::requiredQty).reduce(BigDecimal.ZERO,BigDecimal::add));
        var child=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,originalChild,c.child(),"20","0")))).batches().getFirst();
        var second=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,originalParent,c.common(),"50","0.10")))).batches().getFirst();
        assertNotEquals(first.batchId(),second.batchId(),"Different frozen overproduction allowance prevents WAITING append");
        assertNotEquals(first.planId(),second.planId());
        amount("50",h.db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,first.planId()));
        amount("50",h.db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,second.planId()));
        UUID action=h.db.queryForObject("SELECT action_id FROM preplan_aggregate_batches WHERE id=?",UUID.class,first.batchId());
        var current=h.analyses.detail(c.analysis());
        var after=h.writer.cancel(c.analysis(),action,
                new CancelRequest(current.version(),current.fingerprint(),"fixed-batch-withdraw-"+UUID.randomUUID(),"保留另一个冻结批次"));
        amount("10",h.db.queryForObject("SELECT COALESCE(SUM(retained.current_qty),0) FROM fn_preplan_aggregate_retained_private_sources(?) retained JOIN production_material_analysis_materials canonical ON canonical.id=retained.canonical_material_id WHERE canonical.analysis_item_id=?",BigDecimal.class,c.analysis(),first.anchorAnalysisItemId()));
        amount("20",after.flatMaterials().stream().filter(row->row.goodsId().equals(c.child()))
                .map(MaterialView::requiredQty).reduce(BigDecimal.ZERO,BigDecimal::add));
        amount("0",after.flatMaterials().stream().filter(row->row.goodsId().equals(c.child()))
                .map(MaterialView::planningUncoveredQty).reduce(BigDecimal.ZERO,BigDecimal::add));
        amount("20",h.db.queryForObject("SELECT fn_preplan_action_admitted_qty(action_id) FROM preplan_aggregate_batches WHERE id=?",BigDecimal.class,child.batchId()));
        assertEquals(-1,h.db.queryForObject("SELECT status FROM production_plans WHERE id=?",Integer.class,first.planId()));
        assertEquals(1,h.db.queryForObject("SELECT status FROM production_plans WHERE id=?",Integer.class,second.planId()));
        amount("20",h.db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,child.planId()));
        assertEquals(1,h.db.queryForObject("SELECT COUNT(*) FROM preplan_aggregate_batch_events WHERE batch_id=? AND event_type='CANCEL'",Integer.class,first.batchId()));
    }

    @Test void childReceiptConsumedByFortyRealParentOutputDoesNotGetSubtractedTwice() {
        var c=h.createWithChild("100",1);var initial=h.analyses.detail(c.analysis());
        UUID parentOriginal=original(initial,c.common()),childOriginal=original(initial,c.child());
        var first=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,parentOriginal,c.common(),"100","0")))).batches().getFirst();
        var child=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,childOriginal,c.child(),"100","0")))).batches().getFirst();
        UUID firstAction=h.db.queryForObject("SELECT action_id FROM preplan_aggregate_batches WHERE id=?",UUID.class,first.batchId());
        var current=h.analyses.detail(c.analysis());
        h.writer.cancel(c.analysis(),firstAction,new CancelRequest(current.version(),current.fingerprint(),
                "consumed-parent-withdraw-"+UUID.randomUUID(),"保留独立子工单"));

        h.receive(c,c.material(),"200");refresh(c);
        startWithAvailable(child,"200");
        receive(c,child,c.child(),"40","80");
        amount("40",h.db.queryForObject("SELECT COALESCE(SUM(received_qty),0) FROM fn_preplan_aggregate_retained_private_sources(?)",BigDecimal.class,c.analysis()));
        amount("60",h.db.queryForObject("SELECT COALESCE(SUM(pending_qty),0) FROM fn_preplan_aggregate_retained_private_sources(?)",BigDecimal.class,c.analysis()));

        var replacement=h.writer.submit(c.analysis(),h.command(c,List.of(input(c,parentOriginal,c.common(),"100","0")))).batches().getFirst();
        // The explicit CONTINUOUS route permits this actual 40-unit custody;
        // the other 60 stay unissued instead of requiring fabricated stock.
        startWithAvailable(replacement,"40");
        receive(c,replacement,c.common(),"40","40");
        var after=h.analyses.detail(c.analysis());
        var parentChild=after.flatMaterials().stream().filter(row->row.analysisLineId().equals(replacement.anchorAnalysisItemId())&&row.goodsId().equals(c.child())).findFirst().orElseThrow();
        amount("60",parentChild.requiredQty());
        amount("40",h.db.queryForObject("SELECT COALESCE(SUM(exact.qty),0) FROM preplan_analysis_stock_exact_pegs exact JOIN preplan_supply_action_allocations allocation ON allocation.id=exact.supply_action_allocation_id JOIN preplan_aggregate_batches batch ON batch.action_id=allocation.action_id WHERE batch.id=? AND exact.origin_analysis_material_id=?",BigDecimal.class,child.batchId(),childOriginal));
        amount("40",h.db.queryForObject("SELECT COALESCE(SUM(event.qty),0) FROM preplan_stock_entitlement_events event JOIN preplan_stock_entitlement_events source_lot ON source_lot.id=event.source_entitlement_event_id JOIN preplan_analysis_stock_exact_pegs exact ON exact.id=source_lot.source_exact_peg_id JOIN preplan_supply_action_allocations allocation ON allocation.id=exact.supply_action_allocation_id JOIN preplan_aggregate_batches batch ON batch.action_id=allocation.action_id WHERE batch.id=? AND event.event_type='FORMALIZE'",BigDecimal.class,child.batchId()));
        amount("40",h.db.queryForObject("SELECT COALESCE(SUM(posting.qty_base),0) FROM production_material_settlement_postings posting JOIN production_material_demands demand ON demand.id=posting.demand_id WHERE demand.execution_segment_id=? AND posting.settlement_type='CONSUMED'",BigDecimal.class,segment(replacement)));
        amount("100",h.db.queryForObject("SELECT fn_preplan_action_admitted_qty(action_id) FROM preplan_aggregate_batches WHERE id=?",BigDecimal.class,child.batchId()));
        amount("100",h.db.queryForObject("SELECT COALESCE(SUM(current_qty),0) FROM fn_preplan_aggregate_retained_private_sources(?)",BigDecimal.class,c.analysis()));
        amount("60",h.db.queryForObject("SELECT COALESCE(SUM(pending_qty),0) FROM fn_preplan_aggregate_retained_private_sources(?)",BigDecimal.class,c.analysis()));
        amount("100",h.db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,child.planId()));
    }

    private void startWithAvailable(BatchResult batch,String issued) {
        UUID segment=segment(batch);
        var requests=beans.getBean(ProductionDrawRequestService.class);
        var item=new ProductionDrawRequest.Item(segment,version(segment));
        var preview=requests.preview(new ProductionDrawRequest.PreviewRequest(List.of(item)));
        amount(issued,preview.lines().stream().map(ProductionDrawRequest.Line::qty).reduce(BigDecimal.ZERO,BigDecimal::add));
        requests.submit(new ProductionDrawRequest.SubmitRequest(List.of(item),"consume-draw-"+UUID.randomUUID(),preview.fingerprint()));
        for(UUID document:preview.lines().stream().map(ProductionDrawRequest.Line::drawId).distinct().toList()) {
            var request=new StockDocIssueRequest();request.setIdempotencyKey("consume-issue-"+UUID.randomUUID());
            request.setLines(preview.lines().stream().filter(row->row.drawId().equals(document)).map(row->{
                var line=new StockDocIssueRequest.Line();line.setItemId(row.drawItemId());line.setQty(row.qty());return line;
            }).toList());
            beans.getBean(StockDocService.class).approveAndIssue(document,request);
        }
        beans.getBean(ProductionExecutionSegmentService.class).start(batch.planId(),segment,
                new SegmentTransitionRequest(version(segment),"consume-start-"+UUID.randomUUID()));
    }

    private void receive(AggregateMaterialOrderEndToEndTest.Case c,BatchResult batch,UUID goods,String output,String used) {
        UUID segment=segment(batch),planItem=h.db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",UUID.class,batch.planId());
        var usage=new DailyReportMaterialUsageLine();usage.setDemandId(h.db.queryForObject("SELECT id FROM production_material_demands WHERE execution_segment_id=? AND NOT is_deleted",UUID.class,segment));usage.setQtyBase(new BigDecimal(used));
        UUID report=h.fixture.reportAndApproveExecutionSegment(c.world(),planItem,null,goods,segment,null,output,false,"0",null,null,List.of(usage));
        for(UUID document:h.db.queryForList("SELECT id FROM stock_documents WHERE doc_type='FINISHED_IN' AND source_daily_report_id=? AND NOT is_deleted",UUID.class,report))h.fixture.confirmFinishedInboundFully(document);
        h.fixture.loginAs(c.world().superAdminUserId());
    }

    private UUID segment(BatchResult batch){return selectedSegments.computeIfAbsent(batch.planId(),plan->h.db.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted AND status NOT IN('CANCELLED','REVERSED') ORDER BY CASE status WHEN 'READY' THEN 0 WHEN 'IN_PROGRESS' THEN 1 WHEN 'WAITING' THEN 2 ELSE 3 END,segment_no,id LIMIT 1",UUID.class,plan));}
    private long version(UUID segment){return h.db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,segment);}

    private AnalysisView refresh(AggregateMaterialOrderEndToEndTest.Case c) {
        var view=h.analyses.detail(c.analysis());
        return h.analyses.preview(new PreviewRequest(c.analysis(),view.version(),view.fingerprint(),c.world().warehouseId(),
                "fixed-batch-refresh-"+UUID.randomUUID(),view.products().stream().filter(row->"SALES_ORDER_ITEM".equals(row.sourceType()))
                .map(row->new PreviewItem("SALES_ORDER_ITEM",row.salesOrderItemId(),null,null,null,null,null,row.deliveryDate(),row.requestedQty())).toList()));
    }
    private static UUID original(AnalysisView view,UUID goods) {
        Set<UUID> sources=new HashSet<>();view.products().stream().filter(row->"SALES_ORDER_ITEM".equals(row.sourceType())).forEach(row->sources.add(row.analysisLineId()));
        return view.flatMaterials().stream().filter(row->sources.contains(row.analysisLineId())&&row.goodsId().equals(goods)).findFirst().orElseThrow().materialLineId();
    }
    private static GroupInput input(AggregateMaterialOrderEndToEndTest.Case c,UUID original,UUID goods,String qty,String allowance) {
        var quantity=new BigDecimal(qty);
        return new GroupInput("fixed-"+goods+"-"+UUID.randomUUID(),List.of(original),"MAKE",quantity,false,
                c.workshop(),c.worker(),null,null,null,null,new BigDecimal(allowance),BigDecimal.ZERO,Map.of(original,quantity));
    }
}
