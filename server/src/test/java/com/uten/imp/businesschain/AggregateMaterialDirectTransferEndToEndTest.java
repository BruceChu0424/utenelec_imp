package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.GroupInput;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.dto.*;
import com.uten.imp.features.production.directtransfer.ProductionWorkshopDirectTransferService;
import com.uten.imp.features.production.execution.*;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import com.uten.imp.support.DailyReportApproveRequests;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import java.math.BigDecimal;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
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
class AggregateMaterialDirectTransferEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    AggregateMaterialOrderEndToEndTest flow;
    @BeforeEach void before(){flow=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(flow);flow.before();}
    @AfterEach void after(){SecurityContextHolder.clearContext();}

    @Test void oldChildActuallyHandsOverOnlyItsShareToTheSharedParent() throws Exception {
        var c=flow.createWithChild("1");
        List<UUID> plans=issue(c,c.child(),"1");
        var shared=flow.writer.submit(c.analysis(),flow.command(c,List.of(flow.input(c,c.common(),"MAKE","3",false)))).batches().getFirst();
        UUID source=segment(plans.getFirst()),target=demand(segment(shared.planId()));
        flow.receive(c,c.material(),"6");start(c,source);
        UUID worker=worker(c);flow.fixture.loginAs(worker);
        var candidates=direct().candidates(source,c.child(),null).candidates();
        assertEquals(1,candidates.size());assertEquals(target,candidates.getFirst().demandId());
        amount("1",candidates.getFirst().remainingQty());
        UUID report=transfer(c,source,target,"1","2");
        amount("1",db.queryForObject("SELECT SUM(proof.qty_base) FROM preplan_aggregate_direct_transfer_slices proof JOIN production_workshop_direct_transfer_items transfer ON transfer.id=proof.transfer_item_id JOIN production_daily_report_items item ON item.id=transfer.source_report_item_id WHERE item.report_id=?",BigDecimal.class,report));
        amount("1",db.queryForObject("SELECT SUM(inherited_received_qty) FROM fn_preplan_aggregate_alias_coverage(?)",BigDecimal.class,c.analysis()));
        assertTrue(direct().candidates(source,c.child(),null).candidates().isEmpty());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM stock_document_items item JOIN production_daily_report_items report ON report.id=item.source_daily_report_item_id WHERE report.report_id=? AND fn_finished_in_is_public_output(item.id)",Integer.class,report));
        flow.fixture.loginAs(c.world().superAdminUserId());
        ReflectionTestUtils.invokeMethod(flow.fixture,"drainCosts",c.world());
        UUID inbound=flow.fixture.finishedInDocForReport(report);
        assertThrows(ApiException.class,()->beans.getBean(StockDocService.class).reverseFinishedInbound(inbound),"正式占用仍在时不能越过下游直接红冲");
        for(UUID draw:db.queryForList("SELECT DISTINCT mapping.document_id FROM production_planning_package_documents mapping WHERE mapping.execution_segment_id=(SELECT execution_segment_id FROM production_material_demands WHERE id=?) AND mapping.document_type='DRAW'",UUID.class,target)){
            assertFalse(db.queryForObject("SELECT fn_preplan_aggregate_direct_draw_reversible(?)",Boolean.class,draw));
            var reverse=new StockDocIssueRequest();reverse.setIdempotencyKey("aggregate-direct-unissue-"+draw);reverse.setReason("尚未开工，按原实际出库行对称撤回");
            reverse.setLines(db.query("SELECT id,issued_qty FROM stock_document_items WHERE doc_id=? AND issued_qty>0 AND NOT is_deleted",(rs,index)->{var line=new StockDocIssueRequest.Line();line.setItemId(rs.getObject(1,UUID.class));line.setQty(rs.getBigDecimal(2));return line;},draw));
            if(!reverse.getLines().isEmpty())beans.getBean(StockDocService.class).reverseIssue(draw,reverse);
            assertTrue(db.queryForObject("SELECT fn_preplan_aggregate_direct_draw_reversible(?)",Boolean.class,draw));
            reverseGuardCounterexamples(draw,target);
        }
        ReflectionTestUtils.invokeMethod(flow.fixture,"drainCosts",c.world());
        UUID receivingPackage=db.queryForObject("SELECT package_id FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted",UUID.class,shared.planId());
        beans.getBean(com.uten.imp.features.production.mrp.ProductionPlanningPackageService.class).cancel(shared.planId(),receivingPackage,
            new com.uten.imp.features.production.mrp.PlanningPackageLifecycleRequest("aggregate-direct-cancel-"+receivingPackage,"未投入取消父工单，恢复精确来源后再撤回直送"));
        UUID returnedHead=db.queryForObject("SELECT pool.head_node_id FROM stock_value_pools pool JOIN stock_documents document ON document.warehouse_id=pool.warehouse_id WHERE document.id=? AND pool.goods_id=? AND pool.color_id IS NULL",UUID.class,inbound,c.child());
        beans.getBean(StockDocService.class).reverseFinishedInbound(inbound);
        flow.fixture.loginAs(worker);beans.getBean(ProductionDailyReportService.class).reverse(report);
        assertNotNull(db.queryForObject("SELECT fn_preplan_aggregate_returned_issue_parent(?)",UUID.class,returnedHead),"已完成反向的财务来源证明必须在日报红冲后仍可回溯");
        amount("0",db.queryForObject("SELECT COALESCE(SUM(inherited_received_qty),0) FROM fn_preplan_aggregate_alias_coverage(?)",BigDecimal.class,c.analysis()));
        amount("0",db.queryForObject("SELECT COALESCE(SUM(fn_preplan_aggregate_direct_slice_represented(proof.id)),0) FROM preplan_aggregate_direct_transfer_slices proof JOIN production_workshop_direct_transfer_items transfer ON transfer.id=proof.transfer_item_id JOIN production_daily_report_items item ON item.id=transfer.source_report_item_id WHERE item.report_id=?",BigDecimal.class,report));
        flow.fixture.loginAs(c.world().superAdminUserId());
        var packages=beans.getBean(com.uten.imp.features.production.mrp.ProductionPlanningPackageService.class);
        var preview=packages.preview(shared.planId(),c.world().warehouseId());
        var retry=new com.uten.imp.features.production.mrp.GeneratePlanningPackageRequest();retry.setWarehouseId(c.world().warehouseId());retry.setIdempotencyKey("aggregate-direct-reopen-"+UUID.randomUUID());retry.setPreviewFingerprint(preview.fingerprint());
        retry.setSegments(preview.executionSegments().stream().map(proposed->{var entry=new com.uten.imp.features.production.mrp.GeneratePlanningPackageRequest.ExecutionSegment();entry.setClientSegmentKey(proposed.clientSegmentKey());entry.setSourcePlanItemId(proposed.sourcePlanItemId());entry.setPlannedQty(proposed.plannedQty());entry.setRequestedStatus("WAITING");entry.setWorkshopDepartmentId(c.workshop());entry.setResponsibleEmployeeId(c.worker());entry.setBomFingerprint(proposed.bomFingerprint());return entry;}).toList());
        packages.confirm(shared.planId(),retry);
        UUID newTarget=db.queryForObject("SELECT demand.id FROM production_material_demands demand JOIN production_execution_segments receiving ON receiving.id=demand.execution_segment_id WHERE receiving.plan_id=? AND receiving.status='WAITING' AND NOT receiving.is_deleted AND NOT demand.is_deleted AND demand.status NOT IN('RELEASED','REVERSED')",UUID.class,shared.planId());
        flow.fixture.loginAs(worker);transfer(c,source,newTarget,"1","2");
        amount("1",db.queryForObject("SELECT COALESCE(SUM(inherited_received_qty),0) FROM fn_preplan_aggregate_alias_coverage(?)",BigDecimal.class,c.analysis()));
    }

    @Test void sharedChildActuallyHandsOverToEachOriginalParentWithinOneMemberShare(){
        var c=flow.createWithChild("1");
        var shared=flow.writer.submit(c.analysis(),flow.command(c,List.of(flow.input(c,c.child(),"MAKE","3",false)))).batches().getFirst();
        List<UUID> parents=issue(c,c.common(),"1");
        UUID source=segment(shared.planId());flow.receive(c,c.material(),"6");start(c,source);
        UUID worker=worker(c);flow.fixture.loginAs(worker);
        var candidates=direct().candidates(source,c.child(),null).candidates();assertEquals(3,candidates.size());
        for(var candidate:candidates)amount("1",candidate.remainingQty());
        for(UUID parent:parents){transfer(c,source,demand(segment(parent)),"1","2");}
        assertTrue(direct().candidates(source,c.child(),null).candidates().isEmpty());
        amount("3",db.queryForObject("SELECT SUM(proof.qty_base) FROM preplan_aggregate_direct_transfer_slices proof JOIN preplan_supply_action_allocations allocation ON allocation.id=proof.supply_action_allocation_id JOIN preplan_aggregate_batches batch ON batch.action_id=allocation.action_id WHERE batch.id=?",BigDecimal.class,shared.batchId()));
        for(UUID parent:parents)amount("1",db.queryForObject("SELECT fn_workshop_direct_covered_base_qty(?)",BigDecimal.class,demand(segment(parent))));
    }

    @Test void oneReportHandsOverToThreeSameWorkshopParentsByExplicitAllocations(){
        // 共享子件报 3：工人按先急后缓逐个分给三个同车间上层工单 → 三条转送明细、没有送仓明细。
        var c=flow.createWithChild("1");
        var shared=flow.writer.submit(c.analysis(),flow.command(c,List.of(flow.input(c,c.child(),"MAKE","3",false)))).batches().getFirst();
        List<UUID> parents=issue(c,c.common(),"1");
        UUID source=segment(shared.planId());flow.receive(c,c.material(),"6");start(c,source);
        // BOM 学习口径(V711/V739)：给这个子件建一份学习档案，审核后必须照常入队刷新。
        db.update("INSERT INTO goods_bom_learning_profiles(goods_id,output_unit_id,enabled,blocked_reason) VALUES (?,?,FALSE,'MANUAL_BOM') ON CONFLICT DO NOTHING",
                c.child(),c.world().unitId());
        UUID worker=worker(c);flow.fixture.loginAs(worker);
        var listing=direct().candidates(source,c.child(),null);
        assertEquals(3,listing.candidates().size());assertTrue(listing.blockedTargets().isEmpty());
        List<Integer> priorities=listing.candidates().stream().map(candidate->db.queryForObject("""
                SELECT item.line_priority FROM production_plans plan JOIN production_material_analysis_items item ON item.id=plan.material_analysis_item_id
                WHERE plan.id=?""",Integer.class,candidate.planId())).toList();
        assertEquals(priorities.stream().sorted(java.util.Comparator.nullsLast(java.util.Comparator.naturalOrder())).toList(),priorities,"候选按先急后缓排好");
        UUID report=transfer(c,source,listing.candidates().stream()
                .map(candidate->DailyReportOutputAllocationLine.direct(candidate.demandId(),BigDecimal.ONE)).toList(),"3","6");
        assertEquals(3,db.queryForObject("SELECT count(*) FROM production_daily_report_items WHERE report_id=? AND destination='WORKSHOP' AND NOT is_deleted",Integer.class,report));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_daily_report_items WHERE report_id=? AND destination='WAREHOUSE' AND NOT is_deleted",Integer.class,report));
        assertEquals(1,db.queryForObject("SELECT count(DISTINCT output_batch_id)+count(DISTINCT is_final)-1+count(DISTINCT unit_rate)-1 FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted",Integer.class,report),
                "三块同一产出批次、同一完结标记、同一换算率");
        assertEquals(3,db.queryForObject("SELECT count(DISTINCT direct_transfer_demand_id) FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted",Integer.class,report));
        amount("3",db.queryForObject("SELECT SUM(proof.qty_base) FROM preplan_aggregate_direct_transfer_slices proof JOIN preplan_supply_action_allocations allocation ON allocation.id=proof.supply_action_allocation_id JOIN preplan_aggregate_batches batch ON batch.action_id=allocation.action_id WHERE batch.id=?",BigDecimal.class,shared.batchId()));
        for(UUID parent:parents){
            UUID receiving=demand(segment(parent));
            amount("1",db.queryForObject("SELECT fn_workshop_direct_covered_base_qty(?)",BigDecimal.class,receiving));
            // (b) 每个接收需求的领料过账恰好等于分给它的数量(线边仓领料仍按接收工单一张)。
            amount("1",db.queryForObject("""
                    SELECT COALESCE(SUM(CASE posting_type WHEN 'ISSUE' THEN qty_base WHEN 'ISSUE_REVERSE' THEN -qty_base ELSE 0 END),0)
                    FROM production_material_stock_postings WHERE demand_id=?""",BigDecimal.class,receiving));
        }
        assertTrue(direct().candidates(source,c.child(),null).candidates().isEmpty());
        // (a) 学习分母 = 本工单家族已审报工的 数量×换算率(不含返工补产) = 本次实际产量。
        amount("3",db.queryForObject("""
                SELECT COALESCE(SUM(item.qty*item.unit_rate),0) FROM production_daily_report_items item
                JOIN production_daily_reports report ON report.id=item.report_id
                WHERE item.execution_segment_id IN(SELECT segment_id FROM fn_production_execution_cost_members(fn_production_execution_cost_scope(?)))
                  AND report.status=1 AND NOT report.is_deleted AND NOT item.is_deleted AND item.fqc_recovery_authorization_id IS NULL""",BigDecimal.class,source));
        // (c) 刷新队列照常产生并在提交时排空：本工单家族的学习样本已按本次审核刷新。
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_bom_learning_samples WHERE execution_root_id=fn_production_execution_cost_scope(?)",Integer.class,source));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_bom_learning_refresh_queue WHERE execution_root_id=fn_production_execution_cost_scope(?)",Integer.class,source));
    }

    @Test void mixedWorkshopParentsGetTheirShareDirectAndOnlyTheCrossWorkshopShareGoesToTheWarehouse(){
        var c=flow.createWithChild("1");
        var shared=flow.writer.submit(c.analysis(),flow.command(c,List.of(flow.input(c,c.child(),"MAKE","3",false)))).batches().getFirst();
        Object other=ReflectionTestUtils.invokeMethod(flow.fixture,"productionAssignment","aggregate-other-"+UUID.randomUUID());
        UUID otherWorkshop=ReflectionTestUtils.invokeMethod(other,"workshopId"),otherWorker=ReflectionTestUtils.invokeMethod(other,"workerId");
        var view=flow.analyses.detail(c.analysis());
        var commons=view.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())&&row.nodeRole().equals("BOM_COMPONENT")&&row.requiredQty().signum()>0).toList();
        assertEquals(3,commons.size());
        List<IssueWorkshopPlansRequest.IssuePlanLine> lines=new ArrayList<>();
        for(int index=0;index<commons.size();index++){
            boolean far=index==commons.size()-1;
            lines.add(new IssueWorkshopPlansRequest.IssuePlanLine(commons.get(index).materialLineId(),null,BigDecimal.ONE,null,null,
                    far?otherWorkshop:c.workshop(),null,far?otherWorker:c.worker(),null,null,false,BigDecimal.ZERO));
        }
        List<UUID> parents=flow.ordinary.issueWorkshopPlans(c.analysis(),new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"direct-mixed-"+UUID.randomUUID(),
                c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,lines)).plans().stream().map(row->row.planId()).toList();
        UUID source=segment(shared.planId());flow.receive(c,c.material(),"6");start(c,source);
        UUID worker=worker(c);flow.fixture.loginAs(worker);
        var listing=direct().candidates(source,c.child(),null);
        assertEquals(2,listing.candidates().size());
        assertEquals(1,listing.blockedTargets().size());
        assertEquals("DIFFERENT_WORKSHOP",listing.blockedTargets().getFirst().reasonCode());
        assertTrue(listing.blockedTargets().getFirst().reason().contains("跨车间必须送入仓库"),listing.blockedTargets().getFirst().reason());
        UUID far=parents.stream().map(this::segment).filter(segment->otherWorkshop.equals(db.queryForObject(
                "SELECT workshop_department_id FROM production_execution_segments WHERE id=?",UUID.class,segment))).map(this::demand).findFirst().orElseThrow();
        assertEquals(far,listing.blockedTargets().getFirst().demandId());
        var cross=assertThrows(ApiException.class,()->transfer(c,source,List.of(DailyReportOutputAllocationLine.direct(far,new BigDecimal("3"))),"3","6"));
        assertTrue(cross.getMessage().startsWith("无法转到下一道工序：")&&cross.getMessage().contains("跨车间必须送入仓库"),cross.getMessage());
        List<DailyReportOutputAllocationLine> allocations=new ArrayList<>();
        for(var candidate:listing.candidates())allocations.add(DailyReportOutputAllocationLine.direct(candidate.demandId(),BigDecimal.ONE));
        allocations.add(DailyReportOutputAllocationLine.warehouse(BigDecimal.ONE));
        UUID report=transfer(c,source,allocations,"3","6");
        assertEquals(2,db.queryForObject("SELECT count(*) FROM production_daily_report_items WHERE report_id=? AND destination='WORKSHOP' AND NOT is_deleted",Integer.class,report));
        assertEquals("RECEIVERS_FULL",db.queryForObject("SELECT output_route_reason FROM production_daily_report_items WHERE report_id=? AND destination='WAREHOUSE' AND NOT is_deleted",String.class,report),
                "同车间的两个都分满了，剩下的送入仓库");
        var detail=beans.getBean(ProductionDailyReportService.class).detail(report);
        assertTrue(detail.getItems().stream().anyMatch(item->"能直送的上层工单都已分满，其余送入仓库".equals(item.getOutputRouteReasonText())));
        receiveWarehousePiece(c,report,"AG-CROSS-01");
        // 仓库入库只归到跨车间那一份：三份各收 1，同车间两份没有被入库再占一次。
        List<BigDecimal> received=db.queryForList("SELECT fn_preplan_allocation_received_qty(allocation.id) FROM preplan_supply_action_allocations allocation JOIN preplan_aggregate_batches batch ON batch.action_id=allocation.action_id WHERE batch.id=?",BigDecimal.class,shared.batchId());
        assertEquals(3,received.size());received.forEach(qty->amount("1",qty));
    }

    @Test void warehouseReceiptOfASharedBatchFillsTheMostUrgentShareFirst(){
        // V736：仓库入库分给哪个来源与直送同一「先急后缓」次序，不再按随机 UUID。
        var c=flow.createWithChild("1");
        var shared=flow.writer.submit(c.analysis(),flow.command(c,List.of(flow.input(c,c.child(),"MAKE","3",false)))).batches().getFirst();
        issue(c,c.common(),"1");
        UUID source=segment(shared.planId());flow.receive(c,c.material(),"6");start(c,source);
        UUID worker=worker(c);flow.fixture.loginAs(worker);
        UUID report=transfer(c,source,List.of(),"1","2");
        assertEquals("USER_CHOSEN",db.queryForObject("SELECT output_route_reason FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted",String.class,report));
        UUID inbound=receiveWarehousePiece(c,report,"AG-URGENT-01");
        Integer most=db.queryForObject("""
                SELECT MIN(owner.line_priority) FROM preplan_supply_action_allocations allocation
                JOIN preplan_aggregate_batches batch ON batch.action_id=allocation.action_id
                JOIN production_material_analysis_materials material ON material.id=allocation.analysis_material_id
                JOIN production_material_analysis_items owner ON owner.id=material.analysis_item_id WHERE batch.id=?""",Integer.class,shared.batchId());
        assertEquals(List.of(most),db.queryForList("""
                SELECT owner.line_priority FROM preplan_analysis_stock_exact_pegs peg
                JOIN preplan_supply_action_allocations allocation ON allocation.id=peg.supply_action_allocation_id
                JOIN production_material_analysis_materials material ON material.id=allocation.analysis_material_id
                JOIN production_material_analysis_items owner ON owner.id=material.analysis_item_id
                WHERE peg.source_stock_document_id=?""",Integer.class,inbound));
    }

    @Test void subcontractPreMakeNeverGoesToTheNextProcessAndItsWarehouseReasonSaysWhy(){
        var c=flow.create(true,true,"1");flow.setRoute(c,c.common(),"SUBCONTRACT");
        var raw=flow.input(c,c.common(),"SUBCONTRACT","3",false);
        var group=new GroupInput(raw.clientGroupKey(),raw.materialLineIds(),raw.route(),raw.qty(),false,c.workshop(),c.worker(),null,null,null,null,BigDecimal.ZERO,BigDecimal.ZERO);
        var batch=flow.writer.submit(c.analysis(),flow.command(c,List.of(group))).batches().getFirst();
        UUID source=segment(batch.planId());
        UUID worker=worker(c);flow.fixture.loginAs(worker);
        var listing=direct().candidates(source,c.common(),null);
        assertTrue(listing.candidates().isEmpty());
        assertEquals("SUBCONTRACT_ROUTE",listing.unavailableReasonCode());
        assertTrue(listing.unavailableReason().contains("是委外件"),listing.unavailableReason());
        flow.fixture.loginAs(c.world().superAdminUserId());
        flow.produce(c,batch);
        assertEquals(List.of("SUBCONTRACT_ROUTE"),db.queryForList("""
                SELECT DISTINCT output_route_reason FROM production_daily_report_items
                WHERE execution_segment_id=? AND NOT is_deleted AND NOT is_public_output""",String.class,source));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_daily_report_items WHERE execution_segment_id=? AND destination='WORKSHOP'",Integer.class,source));
    }

    @Test void partialParentCannotTakeTheOldChildQuantityRetainedByItsOriginalParent(){
        var c=flow.createWithChild("1.5");var initial=flow.analyses.detail(c.analysis());
        var child=initial.flatMaterials().stream().filter(row->row.goodsId().equals(c.child())).findFirst().orElseThrow();
        var parent=initial.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())&&row.analysisLineId().equals(child.analysisLineId())).findFirst().orElseThrow();
        UUID oldPlan=flow.ordinary.issueWorkshopPlans(c.analysis(),new IssueWorkshopPlansRequest(initial.version(),initial.fingerprint(),"direct-retained-"+UUID.randomUUID(),c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
            List.of(new IssueWorkshopPlansRequest.IssuePlanLine(child.materialLineId(),null,new BigDecimal("0.5"),null,null,c.workshop(),null,c.worker(),null,null,false,BigDecimal.ZERO)))).plans().getFirst().planId();
        var group=new GroupInput("retained",List.of(parent.materialLineId()),"MAKE",BigDecimal.ONE,false,c.workshop(),c.worker(),null,null,null,null,BigDecimal.ZERO,BigDecimal.ZERO);
        var shared=flow.writer.submit(c.analysis(),flow.command(c,List.of(group))).batches().getFirst();
        UUID source=segment(oldPlan),target=demand(segment(shared.planId()));
        amount("0",db.queryForObject("SELECT fn_workshop_direct_remaining_for_source(?,?)",BigDecimal.class,source,target));
        amount("0.5",db.queryForObject("SELECT fn_preplan_aggregate_source_retained_qty(?)",BigDecimal.class,child.materialLineId()));
        var rest=new GroupInput("retained",List.of(parent.materialLineId()),"MAKE",new BigDecimal("0.5"),false,c.workshop(),c.worker(),null,null,null,null,BigDecimal.ZERO,BigDecimal.ZERO);
        flow.writer.submit(c.analysis(),flow.command(c,List.of(rest)));
        amount("0.5",db.queryForObject("SELECT fn_workshop_direct_remaining_for_source(?,?)",BigDecimal.class,source,target));
    }

    @Test void oneReportSplitsAtTheMemberLimitAndNormalReceiptDoesNotSpendItsDirectProofAgain(){
        var c=flow.createWithChild("1");
        var shared=flow.writer.submit(c.analysis(),flow.command(c,List.of(flow.input(c,c.child(),"MAKE","3",false)))).batches().getFirst();
        issue(c,c.common(),"1");UUID source=segment(shared.planId());
        flow.receive(c,c.material(),"6");start(c,source);UUID worker=worker(c);flow.fixture.loginAs(worker);
        UUID target=direct().candidates(source,c.child(),null).candidates().getFirst().demandId();
        // V736/ADR-127：一个上层工单只缺 1，分给它 2 当场说清楚，不再悄悄把多出的送进仓库。
        var over=assertThrows(ApiException.class,()->transfer(c,source,List.of(DailyReportOutputAllocationLine.direct(target,new BigDecimal("2"))),"2","4"));
        assertTrue(over.getMessage().startsWith("无法转到下一道工序：转给上层工单 ")&&over.getMessage().contains("超过最多可送 1"),over.getMessage());
        UUID report=transfer(c,source,List.of(DailyReportOutputAllocationLine.direct(target,BigDecimal.ONE),
                DailyReportOutputAllocationLine.warehouse(BigDecimal.ONE)),"2","4");
        amount("1",db.queryForObject("SELECT SUM(qty) FROM production_daily_report_items WHERE report_id=? AND destination='WORKSHOP'",BigDecimal.class,report));
        amount("1",db.queryForObject("SELECT SUM(qty) FROM production_daily_report_items WHERE report_id=? AND destination='WAREHOUSE'",BigDecimal.class,report));
        assertEquals("USER_CHOSEN",db.queryForObject("SELECT output_route_reason FROM production_daily_report_items WHERE report_id=? AND destination='WAREHOUSE'",String.class,report),
                "还有两个上层工单能收：送入仓库是工人自己选的");
        receiveWarehousePiece(c,report,"AG-MIXED-01");
        amount("2",db.queryForObject("SELECT SUM(fn_preplan_allocation_received_qty(allocation.id)) FROM preplan_supply_action_allocations allocation JOIN preplan_aggregate_batches batch ON batch.action_id=allocation.action_id WHERE batch.id=?",BigDecimal.class,shared.batchId()));
        flow.fixture.loginAs(worker);var remaining=direct().candidates(source,c.child(),null).candidates();assertEquals(1,remaining.size());amount("1",remaining.getFirst().remainingQty());
        transfer(c,source,remaining.getFirst().demandId(),"1","2");
        amount("3",db.queryForObject("SELECT SUM(fn_preplan_allocation_received_qty(allocation.id)) FROM preplan_supply_action_allocations allocation JOIN preplan_aggregate_batches batch ON batch.action_id=allocation.action_id WHERE batch.id=?",BigDecimal.class,shared.batchId()));
    }

    @Test void sharedWarehouseReceiptCanPartlyFormalizeOnePrivateShareInTheSameTransaction(){
        var c=flow.createWithChild("2");
        var shared=flow.writer.submit(c.analysis(),flow.command(c,List.of(flow.input(c,c.child(),"MAKE","6",false)))).batches().getFirst();
        issue(c,c.common(),"1");UUID source=segment(shared.planId());flow.receive(c,c.material(),"12");start(c,source);
        UUID planItem=db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",UUID.class,source);
        var use=new DailyReportMaterialUsageLine();use.setDemandId(demand(source));use.setQtyBase(new BigDecimal("6"));
        UUID report=flow.fixture.reportAndApproveExecutionSegment(c.world(),planItem,null,c.child(),source,null,"3",false,"0",null,null,List.of(use));
        UUID inbound=flow.fixture.finishedInDocForReport(report);flow.fixture.confirmFinishedInboundFully(inbound);
        assertTrue(db.queryForObject("SELECT COUNT(*)>0 FROM preplan_analysis_stock_exact_pegs exact JOIN stock_reservations reservation ON reservation.id=exact.stock_reservation_id WHERE exact.source_stock_document_id=? AND reservation.released_qty>0 AND reservation.released_qty<reservation.qty AND fn_preplan_aggregate_exact_formalized(exact.id)",Boolean.class,inbound));
        amount("3",db.queryForObject("SELECT SUM(qty) FROM preplan_analysis_stock_exact_pegs WHERE source_stock_document_id=?",BigDecimal.class,inbound));
    }

    List<UUID> issue(AggregateMaterialOrderEndToEndTest.Case c,UUID goods,String qty){
        var view=flow.analyses.detail(c.analysis());
        return flow.ordinary.issueWorkshopPlans(c.analysis(),new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"direct-plans-"+UUID.randomUUID(),c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                view.flatMaterials().stream().filter(row->row.goodsId().equals(goods)&&row.nodeRole().equals("BOM_COMPONENT")&&row.requiredQty().signum()>0)
                .map(row->new IssueWorkshopPlansRequest.IssuePlanLine(row.materialLineId(),null,new BigDecimal(qty),null,null,c.workshop(),null,c.worker(),null,null,false,BigDecimal.ZERO)).toList()))
                .plans().stream().map(row->row.planId()).toList();
    }
    void start(AggregateMaterialOrderEndToEndTest.Case c,UUID segment){
        var draws=beans.getBean(ProductionDrawRequestService.class);var stock=beans.getBean(StockDocService.class);
        var request=new ProductionDrawRequest.Item(segment,flow.version(segment));
        var shown=draws.preview(new ProductionDrawRequest.PreviewRequest(List.of(request)));
        draws.submit(new ProductionDrawRequest.SubmitRequest(List.of(request),"direct-draw-"+segment,shown.fingerprint()));
        for(UUID doc:shown.lines().stream().map(ProductionDrawRequest.Line::drawId).distinct().toList()){
            var issue=new StockDocIssueRequest();issue.setIdempotencyKey("direct-issue-"+doc);
            issue.setLines(shown.lines().stream().filter(line->doc.equals(line.drawId())).map(row->{var line=new StockDocIssueRequest.Line();line.setItemId(row.drawItemId());line.setQty(row.qty());return line;}).toList());stock.approveAndIssue(doc,issue);
        }
        beans.getBean(ProductionExecutionSegmentService.class).start(db.queryForObject("SELECT plan_id FROM production_execution_segments WHERE id=?",UUID.class,segment),segment,new SegmentTransitionRequest(flow.version(segment),"direct-start-"+segment));
    }
    UUID worker(AggregateMaterialOrderEndToEndTest.Case c){
        UUID user=flow.fixture.createUserWithPerms(c.world(),"aggregate-direct-"+UUID.randomUUID(),"production_execution:view","production_execution:start","production_material:settle","production_daily_report:view","production_daily_report:create","production_daily_report:approve","production_daily_report:reverse","production_direct_transfer:approve");
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",c.workshop(),user);return user;
    }
    UUID transfer(AggregateMaterialOrderEndToEndTest.Case c,UUID source,UUID target,String quantity,String used){
        return transfer(c,source,List.of(DailyReportOutputAllocationLine.direct(target,new BigDecimal(quantity))),quantity,used);
    }
    UUID transfer(AggregateMaterialOrderEndToEndTest.Case c,UUID source,List<DailyReportOutputAllocationLine> allocations,String quantity,String used){
        var report=new DailyReportSaveRequest();report.setIdempotencyKey("aggregate-direct-report-"+UUID.randomUUID());report.setBillDate(BusinessTime.today());report.setWarehouseId(c.world().warehouseId());report.setDepartmentId(c.workshop());report.setWorkerIds(List.of(c.worker()));
        var item=new DailyReportItemLine();item.setLineNo(1);item.setExecutionSegmentId(source);item.setPlanItemId(db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",UUID.class,source));item.setGoodsId(c.child());item.setUnitId(c.world().unitId());item.setUnitRate(BigDecimal.ONE);item.setQty(new BigDecimal(quantity));item.setAllocations(allocations);report.setItems(List.of(item));
        var usage=new DailyReportMaterialUsageLine();usage.setDemandId(demand(source));usage.setQtyBase(new BigDecimal(used));report.setMaterialLines(List.of(usage));
        var reports=beans.getBean(ProductionDailyReportService.class);UUID id=reports.create(report).getId();reports.approve(id,DailyReportApproveRequests.freshKey());return id;
    }
    /** 送仓明细走仓库到货登记、品质合格、点收入库，返回入库单。 */
    UUID receiveWarehousePiece(AggregateMaterialOrderEndToEndTest.Case c,UUID report,String location){
        UUID ordinaryItem=db.queryForObject("SELECT id FROM production_daily_report_items WHERE report_id=? AND destination='WAREHOUSE' AND NOT is_deleted",UUID.class,report);
        flow.fixture.loginAs(c.world().superAdminUserId());
        beans.getBean(com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService.class).register(report,
            new com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationRequest("aggregate-arrival-"+report,c.world().warehouseId(),
                List.of(new com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationItemRequest(ordinaryItem,location)),null));
        UUID inspection=db.queryForObject("SELECT id FROM production_fqc_inspections WHERE source_report_item_id=?",UUID.class,ordinaryItem);
        BigDecimal qty=db.queryForObject("SELECT qty FROM production_daily_report_items WHERE id=?",BigDecimal.class,ordinaryItem);
        beans.getBean(com.uten.imp.features.production.quality.ProductionFqcInspectionService.class).decide(inspection,
            new com.uten.imp.features.production.quality.ProductionFqcContracts.DecisionRequest("PASS",qty,null,null,null,"aggregate-pass-"+inspection));
        UUID inbound=db.queryForObject("SELECT DISTINCT doc_id FROM stock_document_items WHERE source_daily_report_item_id=?",UUID.class,ordinaryItem);
        flow.fixture.confirmFinishedInboundFully(inbound);
        return inbound;
    }
    UUID segment(UUID plan){return db.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted",UUID.class,plan);}
    UUID demand(UUID segment){return db.queryForObject("SELECT id FROM production_material_demands WHERE execution_segment_id=? AND NOT is_deleted",UUID.class,segment);}
    ProductionWorkshopDirectTransferService direct(){return beans.getBean(ProductionWorkshopDirectTransferService.class);}

    /** Negative projections use the actual completed source chain copied into a
     * rollback-only schema. No immutable real source rows are edited or forged. */
    void reverseGuardCounterexamples(UUID document,UUID target) throws Exception {
        try(var connection=Objects.requireNonNull(db.getDataSource()).getConnection();var statement=connection.createStatement()){
            connection.setAutoCommit(false);String schema="direct_guard_"+UUID.randomUUID().toString().replace("-","");
            statement.execute("CREATE SCHEMA "+schema);statement.execute("SET LOCAL search_path TO "+schema+",public");
            for(String table:List.of("stock_documents","stock_document_items","production_material_stock_postings","production_workshop_direct_source_allocations",
                    "production_workshop_direct_transfer_items","production_workshop_direct_transfers","preplan_aggregate_direct_transfer_slices","production_material_demands",
                    "production_execution_segment_events","production_daily_report_items","stock_value_nodes","stock_value_events","stock_value_edges","stock_value_pools","stock_value_position_transfers","production_material_movement_links","production_material_stock_events"))com.uten.imp.support.MigratedProjectionSchema.copyTablesWithDataFromMigratedCatalog(connection,table);
            String definition;try(var result=statement.executeQuery("SELECT pg_get_functiondef('public.fn_preplan_aggregate_direct_draw_reversible(uuid)'::regprocedure)")){result.next();definition=result.getString(1);}
            statement.execute(definition.replace("FUNCTION public.","FUNCTION "+schema+"."));
            try(var result=statement.executeQuery("SELECT fn_preplan_aggregate_direct_draw_reversible('"+document+"')")){assertTrue(result.next()&&result.getBoolean(1));}
            var save=connection.setSavepoint();
            statement.execute("UPDATE stock_document_items SET issued_qty=0.0001 WHERE doc_id='"+document+"'");
            try(var result=statement.executeQuery("SELECT fn_preplan_aggregate_direct_draw_reversible('"+document+"')")){assertTrue(result.next());assertFalse(result.getBoolean(1),"一行仍有实发不得关闭");}connection.rollback(save);
            statement.execute("INSERT INTO production_execution_segment_events(execution_segment_id,action) SELECT execution_segment_id,'START' FROM production_material_demands WHERE id='"+target+"'");
            try(var result=statement.executeQuery("SELECT fn_preplan_aggregate_direct_draw_reversible('"+document+"')")){assertTrue(result.next());assertFalse(result.getBoolean(1),"接收已经开工不得关闭");}connection.rollback(save);
            // Add one uncovered source to an otherwise fully proved real line.
            statement.execute("INSERT INTO production_workshop_direct_source_allocations(id,transfer_item_id,stock_reservation_id,qty_base) SELECT gen_random_uuid(),gen_random_uuid(),posting.reservation_id,0.0001 FROM production_material_stock_postings posting JOIN stock_document_items item ON item.id=posting.stock_document_item_id WHERE item.doc_id='"+document+"' LIMIT 1");
            try(var result=statement.executeQuery("SELECT fn_preplan_aggregate_direct_draw_reversible('"+document+"')")){assertTrue(result.next());assertFalse(result.getBoolean(1),"一份来源缺少共享证明也不得关闭");}
            connection.rollback(save);
            UUID head;try(var result=statement.executeQuery("SELECT DISTINCT pool.head_node_id FROM stock_value_pools pool JOIN stock_documents doc ON doc.warehouse_id=pool.warehouse_id JOIN stock_document_items item ON item.doc_id=doc.id AND item.goods_id=pool.goods_id AND item.color_id IS NOT DISTINCT FROM pool.color_id WHERE doc.id='"+document+"'")){assertTrue(result.next());head=result.getObject(1,UUID.class);}
            try(var result=statement.executeQuery("SELECT pg_get_functiondef('public.fn_preplan_aggregate_returned_issue_parent(uuid)'::regprocedure)")){result.next();definition=result.getString(1);}statement.execute(definition.replace("FUNCTION public.","FUNCTION "+schema+"."));
            try(var result=statement.executeQuery("SELECT fn_preplan_aggregate_returned_issue_parent('"+head+"')")){assertTrue(result.next());assertNotNull(result.getObject(1),"完整实际退回应追到原库存头");}
            var costSave=connection.setSavepoint();
            statement.execute("UPDATE stock_value_events SET qty_base=qty_base/2 WHERE id=(SELECT creation_event_id FROM stock_value_nodes WHERE id='"+head+"')");
            try(var result=statement.executeQuery("SELECT fn_preplan_aggregate_returned_issue_parent('"+head+"')")){assertTrue(result.next());assertNull(result.getObject(1),"未满额退回不能证明成本未被使用");}connection.rollback(costSave);
            statement.execute("INSERT INTO stock_value_position_transfers(id,event_id,source_root_id) SELECT gen_random_uuid(),creation_event_id,gen_random_uuid() FROM stock_value_nodes WHERE id='"+head+"'");
            try(var result=statement.executeQuery("SELECT fn_preplan_aggregate_returned_issue_parent('"+head+"')")){assertTrue(result.next());assertNull(result.getObject(1),"多源退回不能猜测原成本");}connection.rollback(costSave);
            statement.execute("UPDATE stock_value_nodes SET range_to=range_from+0.0001 WHERE id=(SELECT root.return_head_id FROM stock_value_position_transfers transfer JOIN stock_value_nodes root ON root.id=transfer.source_root_id WHERE transfer.event_id=(SELECT creation_event_id FROM stock_value_nodes WHERE id='"+head+"'))");
            try(var result=statement.executeQuery("SELECT fn_preplan_aggregate_returned_issue_parent('"+head+"')")){assertTrue(result.next());assertNull(result.getObject(1),"仍有在制占用不能撤回原成本");}
            connection.rollback();
        }
    }
}
