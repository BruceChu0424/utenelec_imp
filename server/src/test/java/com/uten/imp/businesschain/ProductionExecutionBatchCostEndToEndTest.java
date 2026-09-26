package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.execution.ProductionExecutionBatch;
import com.uten.imp.features.production.execution.ProductionExecutionSegmentService;
import com.uten.imp.features.production.execution.SegmentTransitionRequest;
import com.uten.imp.features.production.mrp.ProductionExecutionBatchService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.allocation.ProductionMaterialSettlementService;
import com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest;
import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.stock.valuation.InventoryValueWorkService;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.junit.jupiter.api.Assertions.*;

/** Actual monetary assertions over the real split, issue, reporting, stock and value-worker chain. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProductionExecutionBatchCostEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired ProductionExecutionBatchService batches;
    @Autowired ProductionExecutionSegmentService segments;
    @Autowired ProductionMaterialSettlementService settlements;
    @Autowired StockDocService stock;
    @Autowired InventoryValueWorkService worker;
    FullChainEndToEndTest fixture;
    @BeforeEach void prepare(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}
    @AfterEach void logout(){org.springframework.security.core.context.SecurityContextHolder.clearContext();}

    @Test void fixedBatchCostRemainsForLaterOutputAndRepricesEarlySalesAfterAnActualConsumptionCorrection() {
        Case c=create("split-cost-cogs");
        var first=split(c,c.rootSegment(),"40");issueAndStart(c,first);
        finish(c,first.batchSegmentId(),"40",c.world());drain(c);
        UUID posting=consumptionPosting(first.batchSegmentId());
        money("40",stockValue(c.world().warehouseId(),c.product()));money("60",costHeld(c));
        assertEquals(1,count("SELECT count(*) FROM stock_value_production_cost_objects WHERE execution_segment_id=?",c.rootSegment()));
        assertEquals(0,count("SELECT count(*) FROM stock_value_production_cost_objects object JOIN production_execution_segments segment ON segment.id=object.execution_segment_id WHERE segment.split_root_segment_id=?",c.rootSegment()));
        UUID shipment=fixture.createShipment(c.world(),c.orderItem(),c.product(),"40");fixture.shipThroughWarehouse(shipment);drain(c);
        money("40",cogs(c));money("60",costHeld(c));

        var second=split(c,first.remainingSegmentId(),"60");assertTrue(second.documentIds().isEmpty());issueAndStart(c,second);
        var secondWorld=withWarehouse(c.world(),newWarehouse("split-cost-cogs-second"));
        finish(c,second.batchSegmentId(),"60",secondWorld);drain(c);
        money("40",cogs(c));money("60",stockValue(secondWorld.warehouseId(),c.product()));money("0",costHeld(c));
        assertEquals(2,count("SELECT count(*) FROM stock_value_production_cost_outputs WHERE execution_segment_id=?",c.rootSegment()));
        assertEquals(2,count("SELECT count(DISTINCT movement.warehouse_id) FROM stock_value_production_cost_outputs output JOIN stock_movements movement ON movement.id=output.movement_id WHERE output.execution_segment_id=?",c.rootSegment()));
        money("100",db.queryForObject("SELECT target_qty_base FROM stock_value_production_cost_revisions WHERE id=(SELECT current_revision_id FROM stock_value_production_cost_objects WHERE execution_segment_id=?)",BigDecimal.class,c.rootSegment()));
        assertEquals("FINAL",db.queryForObject("SELECT state FROM stock_value_production_cost_objects WHERE execution_segment_id=?",String.class,c.rootSegment()));

        var correction=new ProductionMaterialSettlementRequest();correction.setExecutionSegmentId(first.batchSegmentId());
        correction.setIdempotencyKey("cost-correction-"+posting);correction.setReason("按原登记纠正实际消耗，剩余材料留在车间");
        var line=new ProductionMaterialSettlementRequest.Line();line.setDemandId(db.queryForObject("SELECT demand_id FROM production_material_settlement_postings WHERE id=?",UUID.class,posting));
        line.setSourcePostingId(posting);line.setSettlementType("CONSUMED");line.setQtyBase(new BigDecimal("0.5"));correction.setLines(List.of(line));
        settlements.reverse(c.plan(),correction,c.world().superAdminUserId());drain(c);
        money("20",cogs(c));money("30",stockValue(secondWorld.warehouseId(),c.product()));money("0",costHeld(c));
        money("50",db.queryForObject("SELECT COALESCE(sum(node.owned_value_local),0) FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=? AND node.owner_kind='WIP'",BigDecimal.class,c.material()));
    }

    @Test void reversingAndReceivingALaterChildOutputRetainsItsOriginalRootCostPoolAndPhysicalMovement() {
        Case c=create("split-cost-reverse");var first=split(c,c.rootSegment(),"40");issueAndStart(c,first);
        finish(c,first.batchSegmentId(),"40",c.world());drain(c);
        var second=split(c,first.remainingSegmentId(),"60");issueAndStart(c,second);
        var other=withWarehouse(c.world(),newWarehouse("split-cost-reverse-second"));
        UUID secondDoc=finish(c,second.batchSegmentId(),"60",other);drain(c);
        stock.reverseFinishedInbound(secondDoc);drain(c);
        money("40",stockValue(c.world().warehouseId(),c.product()));money("0",stockValue(other.warehouseId(),c.product()));money("60",costHeld(c));
        assertEquals(1,count("SELECT count(*) FROM stock_value_production_cost_outputs WHERE execution_segment_id=? AND withdrawn_movement_id IS NOT NULL",c.rootSegment()));
        UUID replacement=db.queryForObject("SELECT document.id FROM stock_documents document JOIN stock_document_items item ON item.doc_id=document.id WHERE document.doc_type='FINISHED_IN' AND document.status=0 AND NOT document.is_deleted AND item.execution_segment_id=?",UUID.class,second.batchSegmentId());
        fixture.confirmFinishedInboundFully(replacement);drain(c);
        money("40",stockValue(c.world().warehouseId(),c.product()));money("60",stockValue(other.warehouseId(),c.product()));money("0",costHeld(c));
        assertEquals(3,count("SELECT count(DISTINCT movement_id) FROM stock_value_production_cost_outputs WHERE execution_segment_id=?",c.rootSegment()));
        assertEquals(0,count("SELECT count(*) FROM stock_value_production_cost_outputs output JOIN stock_movements movement ON movement.id=output.movement_id JOIN stock_document_items item ON item.id=movement.source_item_id WHERE output.execution_segment_id=? AND fn_production_execution_cost_scope(item.execution_segment_id)<>output.execution_segment_id",c.rootSegment()));
    }

    @Test void anEarlyFinalReportCannotDiscardTheRemainingApprovedBatchOrItsCostBasis() {
        Case c=create("split-cost-final-target");var first=split(c,c.rootSegment(),"40");issueAndStart(c,first);
        var failure=assertThrows(com.uten.imp.common.web.ApiException.class,
                ()->finish(c,first.batchSegmentId(),"35",c.world(),true));
        assertTrue(failure.getMessage().contains("分批报工不调整原批准总量"));
        money("100",db.queryForObject("SELECT planned_qty FROM production_execution_segments WHERE id=?",BigDecimal.class,c.rootSegment()));
        money("40",db.queryForObject("SELECT planned_qty FROM production_execution_segments WHERE id=?",BigDecimal.class,first.batchSegmentId()));
        money("60",db.queryForObject("SELECT planned_qty FROM production_execution_segments WHERE id=?",BigDecimal.class,first.remainingSegmentId()));
        money("100",db.queryForObject("SELECT fn_production_execution_cost_target(?)",BigDecimal.class,c.rootSegment()));
        drain(c);
        money("0",stockValue(c.world().warehouseId(),c.product()));money("0",costHeld(c));
        money("100",db.queryForObject("SELECT COALESCE(sum(node.owned_value_local),0) FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=? AND node.owner_kind='WIP'",BigDecimal.class,c.material()));
        assertEquals(0,count("SELECT count(*) FROM production_material_settlement_postings posting JOIN production_material_demands demand ON demand.id=posting.demand_id WHERE demand.plan_id=?",c.plan()));
    }

    private Case create(String tag) {
        var w=fixture.seedWorld(tag);fixture.loginAs(w.superAdminUserId());
        UUID product=UUID.randomUUID(),material=UUID.randomUUID(),workshop=UUID.randomUUID(),employee=UUID.randomUUID();
        fixture.insertGoods(product,"ROOT-"+tag,"分批成本成品","自制",w.unitId(),w.unitLegacy());
        fixture.insertGoods(material,"MAT-"+tag,"固定批耗材料","采购",w.unitId(),w.unitLegacy());fixture.insertBom(product,material,"1");
        db.update("UPDATE goods_bom_items SET consumption_basis='FIXED_BATCH',basis_output_qty=100 WHERE goods_id=?",product);
        UUID production=db.queryForObject("SELECT id FROM departments WHERE code='DEPT_PROD'",UUID.class);
        db.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES(?,?,?,?,'二级班组')",workshop,"W-"+tag,"成本分批车间",production);
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')",employee,"BATCH-EMP-"+tag,"分批负责人",workshop);
        UUID order=fixture.createApprovedOrder(w,product,"100","100");UUID orderItem=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
        var origin=new PreviewItem("SALES_ORDER_ITEM",orderItem,null,null,null,null,null,BusinessTime.today().plusDays(10),new BigDecimal("100"));
        var view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"preview-"+tag,List.of(origin)));
        analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"routes-"+tag,
            view.flatMaterials().stream().map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),row.goodsId().equals(product)?"MAKE":"BUY",null)).toList()));
        view=analyses.detail(view.analysisId());
        UUID plan=commands.issueWorkshopPlans(view.analysisId(),new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"issue-"+tag,w.warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null,view.products().getFirst().analysisLineId(),new BigDecimal("100"),BusinessTime.today(),BusinessTime.today().plusDays(10),workshop,null,employee,null,null)))).plans().getFirst().planId();
        UUID segment=db.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=? AND status='WAITING'",UUID.class,plan);
        // V606：拆批场景必须**先改选分批路线再收料**——齐套段的「到货即自动提升」会在
        // 收料同事务建领料单并冻结路线(这正是给用户的提示语顺序)。
        fixture.loginAs(w.superAdminUserId());
        segments.confirmRoute(plan,segment,new com.uten.imp.features.production.execution.SegmentRouteConfirmRequest(version(segment),"route-BATCH-setup-"+segment,"BATCH"));
        var opening=new StockDocSaveRequest();opening.setDocType("OTHER_IN");opening.setWarehouseId(w.warehouseId());opening.setBillDate(BusinessTime.today());
        var line=new StockDocItemLine();line.setGoodsId(material);line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(BigDecimal.ONE);line.setPrice(new BigDecimal("100"));line.setAmountOriginal(new BigDecimal("100"));line.setAmountLocal(new BigDecimal("100"));opening.setItems(List.of(line));stock.approve(stock.create(opening).getId());
        return new Case(w,product,material,plan,segment,orderItem);
    }
    private ProductionExecutionBatch.Result split(Case c,UUID segment,String quantity){fixture.loginAs(c.world().superAdminUserId());segments.confirmRoute(c.plan(),segment,new com.uten.imp.features.production.execution.SegmentRouteConfirmRequest(version(segment),"route-BATCH-"+segment,"BATCH"));var preview=batches.preview(new ProductionExecutionBatch.PreviewRequest(segment,version(segment),new BigDecimal(quantity)));return batches.submit(new ProductionExecutionBatch.SubmitRequest(segment,preview.expectedVersion(),preview.quantity(),preview.fingerprint(),"split-cost-"+segment));}
    private void issueAndStart(Case c,ProductionExecutionBatch.Result batch){fixture.loginAs(c.world().superAdminUserId());if(!batch.documentIds().isEmpty()){var request=new StockDocIssueBatchRequest();request.setIdempotencyKey("issue-cost-"+batch.batchSegmentId());request.setDocIds(batch.documentIds());stock.issueFullBatch(request);}segments.start(c.plan(),batch.batchSegmentId(),new SegmentTransitionRequest(version(batch.batchSegmentId()),"start-cost-"+batch.batchSegmentId()));}
    private UUID consumptionPosting(UUID segment){
        UUID posting=db.queryForObject("""
                SELECT posting.id FROM production_material_settlement_postings posting
                JOIN production_material_demands demand ON demand.id=posting.demand_id
                JOIN production_material_settlement_events event ON event.id=posting.event_id
                WHERE demand.execution_segment_id=? AND posting.source_posting_id IS NULL
                  AND posting.settlement_type='CONSUMED' AND event.daily_report_id IS NOT NULL
                """,UUID.class,segment);
        money("1",db.queryForObject("SELECT qty_base FROM production_material_settlement_postings WHERE id=?",BigDecimal.class,posting));
        return posting;
    }
    private UUID finish(Case c,UUID segment,String quantity,FullChainEndToEndTest.World world){return finish(c,segment,quantity,world,false);}
    private UUID finish(Case c,UUID segment,String quantity,FullChainEndToEndTest.World world,boolean finalReport){
        fixture.loginAs(c.world().superAdminUserId());
        UUID planItem=db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",UUID.class,segment);
        UUID allocation=db.queryForObject("SELECT id FROM execution_segment_sales_allocations WHERE execution_segment_id=?",UUID.class,segment);
        // The first split physically consumes the single fixed-batch input in its
        // report; later splits have no new input and retain that original cost pool.
        var uses=db.queryForList("SELECT id,required_qty FROM production_material_demands WHERE execution_segment_id=? AND NOT is_deleted",segment).stream().map(row->{
            var use=new com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageLine();
            use.setDemandId((UUID)row.get("id"));use.setQtyBase((BigDecimal)row.get("required_qty"));return use;
        }).toList();
        if(uses.isEmpty() || uses.stream().allMatch(use->use.getQtyBase().signum()==0))
            assertEquals(Boolean.TRUE,db.queryForObject("SELECT fn_split_batch_empty_issued(?)",Boolean.class,segment));
        UUID report=fixture.reportAndApproveExecutionSegment(world,planItem,c.orderItem(),c.product(),segment,allocation,quantity,finalReport,"0",null,null,uses);
        UUID document=fixture.finishedInDocForReport(report);fixture.confirmFinishedInboundFully(document);return document;
    }
    private void drain(Case c){InventoryValueWorkTestSupport.drain(worker,db,List.of(c.product(),c.material()));}
    private long version(UUID segment){return db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,segment);}
    private int count(String sql,Object... args){return db.queryForObject(sql,Integer.class,args);}
    private BigDecimal stockValue(UUID warehouse,UUID goods){return db.queryForObject("SELECT COALESCE(sum(amount_local),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,warehouse,goods);}
    private BigDecimal costHeld(Case c){return db.queryForObject("SELECT COALESCE(sum(owned_value_local),0) FROM stock_value_nodes WHERE owner_kind='COST_WIP' AND owner_id=?",BigDecimal.class,c.rootSegment());}
    private BigDecimal cogs(Case c){return db.queryForObject("SELECT COALESCE(sum(node.owned_value_local),0) FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE node.owner_kind='COGS' AND pool.goods_id=?",BigDecimal.class,c.product());}
    private UUID newWarehouse(String tag){UUID id=UUID.randomUUID();db.update("INSERT INTO warehouses(id,code,name,status,is_accountable) VALUES(?,?,?,'使用',TRUE)",id,"WH-"+tag,"分批成品实收仓");return id;}
    private static FullChainEndToEndTest.World withWarehouse(FullChainEndToEndTest.World w,UUID warehouse){return new FullChainEndToEndTest.World(w.departmentId(),w.employeeId(),w.superAdminUserId(),w.goodsA(),w.goodsB(),w.goodsC(),w.goodsD(),w.goodsE(),w.clientId(),w.supplierId(),warehouse,w.unitId(),w.currencyId(),w.colorId(),w.unitLegacy());}
    private static void money(String expected,BigDecimal actual){assertEquals(0,new BigDecimal(expected).compareTo(actual),()->"expected "+expected+", actual "+actual);}
    private record Case(FullChainEndToEndTest.World world,UUID product,UUID material,UUID plan,UUID rootSegment,UUID orderItem){}
}
