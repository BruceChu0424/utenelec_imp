package com.uten.imp.businesschain;

import com.uten.imp.support.DailyReportApproveRequests;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewItem;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest;
import com.uten.imp.features.production.execution.ProductionDrawRequest;
import com.uten.imp.features.production.execution.ProductionExecutionBatch;
import com.uten.imp.features.production.execution.ProductionExecutionSegmentService;
import com.uten.imp.features.production.execution.SegmentTransitionRequest;
import com.uten.imp.features.production.mrp.ProductionExecutionBatchService;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
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

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.IssueWorkshopPlansRequest;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.RouteDecision;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.RouteRequest;
import static org.junit.jupiter.api.Assertions.*;

/** Adversarial provenance checks using real reports, physical receipts and material postings. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false", "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.policy-intelligence.enabled=false", "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only", "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class WorkshopSupplyAdversarialEndToEndTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired ProductionExecutionBatchService batches;
    @Autowired ProductionExecutionSegmentService segments;
    @Autowired ProductionDailyReportService reports;
    @Autowired com.uten.imp.features.production.execution.ProductionDrawRequestService drawRequests;
    @Autowired StockDocService stock;
    FullChainEndToEndTest fixture;

    @BeforeEach
    void prepare() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
    }

    @AfterEach
    void logout() {
        org.springframework.security.core.context.SecurityContextHolder.clearContext();
    }

    @Test
    void aSameSkuManualTaskCannotReceiveAnUnrelatedAnalysisChild() {
        Case c=create("adv-unrelated",false);
        UUID[] unrelated=manualTarget(c,"adv-unrelated-target");
        fixture.loginAs(c.workerUser());
        var direct=beans.getBean(com.uten.imp.features.production.directtransfer.ProductionWorkshopDirectTransferService.class);
        assertFalse(direct.candidates(c.childSegment(),c.child(),null).candidates().stream()
                .anyMatch(candidate->candidate.executionSegmentId().equals(unrelated[1])),
                "同车间同SKU不能替代真实父子责任关系");
        String candidateSql=(String)org.springframework.test.util.ReflectionTestUtils.getField(direct,"CANDIDATE_SQL");
        var plan=new org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate(db).queryForList(
                "EXPLAIN (ANALYZE,BUFFERS) "+candidateSql,
                new org.springframework.jdbc.core.namedparam.MapSqlParameterSource("segmentId",c.childSegment())
                        .addValue("goodsId",c.child()).addValue("colorId",null),String.class);
        System.out.println("V615_CANDIDATE_PREFILTER_EXPLAIN\n"+String.join("\n",plan));
        assertTrue(plan.stream().anyMatch(line->line.contains("CTE candidate_scope")));
        assertThrows(ApiException.class,()->transferTo(c,unrelated[2],"10"));
    }

    @Test
    void linkedManualRecipientsCannotBorrowEachOthersDedicatedLineSideQuantity() {
        ManualFamily family=manualFamily("adv-dedicated");
        Case c=family.context();UUID[] first=family.first(),second=family.second();
        transferTo(c,first[2],"10");
        transferTo(c,second[2],"90");
        fixture.loginAs(c.workerUser());
        confirmRoute(first[0],first[1],"CONTINUOUS");
        qty("10",issued(first[2]));
        qty("90",db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,c.lineSide(),c.child()));
        confirmRoute(second[0],second[1],"CONTINUOUS");
        qty("90",issued(second[2]));
        qty("0",db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,c.lineSide(),c.child()));
    }

    @Test
    void concurrentRecipientsCannotDoubleSpendTheSamePhysicalPool() throws Exception {
        ManualFamily family=manualFamily("adv-parallel");
        Case c=family.context();UUID[] first=family.first(),second=family.second();
        UUID a=transferTo(c,first[2],"10"),b=transferTo(c,second[2],"90");
        var notices=beans.getBean(com.uten.imp.features.notice.ChainNoticeService.class);
        assertEquals(Boolean.TRUE,org.springframework.test.util.ReflectionTestUtils.invokeMethod(
                notices,"workshopArrivalCanBenefit",first[1],"DIRECT_REPORT",List.of(a)));
        assertEquals(Boolean.FALSE,org.springframework.test.util.ReflectionTestUtils.invokeMethod(
                notices,"workshopArrivalCanBenefit",first[1],"DIRECT_REPORT",List.of(b)),
                "另一接收方的同SKU报工不能充作本任务到货证据");
        var ready=new java.util.concurrent.CountDownLatch(2);var go=new java.util.concurrent.CountDownLatch(1);
        try(var pool=java.util.concurrent.Executors.newFixedThreadPool(2)) {
            var futures=new java.util.ArrayList<java.util.concurrent.Future<?>>();
            for(UUID[] target:List.of(first,second))futures.add(pool.submit(()->{
                fixture.loginAs(c.workerUser());ready.countDown();
                try { if(!go.await(20,java.util.concurrent.TimeUnit.SECONDS))throw new AssertionError("start barrier timeout");
                    confirmRoute(target[0],target[1],"CONTINUOUS");
                } catch(InterruptedException e) {Thread.currentThread().interrupt();throw new RuntimeException(e);}
                finally {org.springframework.security.core.context.SecurityContextHolder.clearContext();}
            }));
            assertTrue(ready.await(20,java.util.concurrent.TimeUnit.SECONDS));go.countDown();
            for(var future:futures)future.get(60,java.util.concurrent.TimeUnit.SECONDS);
        }
        qty("10",issued(first[2]));qty("90",issued(second[2]));
        qty("100",db.queryForObject("""
                SELECT SUM(allocation.effective_qty) FROM v_workshop_direct_source_allocations allocation
                JOIN stock_reservations reservation ON reservation.id=allocation.stock_reservation_id
                WHERE reservation.demand_id IN (?,?)
                """,BigDecimal.class,first[2],second[2]));
        qty("0",db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,c.lineSide(),c.child()));
    }

    @Test
    void receiverPausedAfterSelectionCannotAcceptAReport() {
        Case c=create("adv-paused",false);
        fixture.loginAs(c.world().superAdminUserId());
        db.update("UPDATE production_plans SET is_stopped=TRUE WHERE id=?",c.plan());
        fixture.loginAs(c.workerUser());
        assertThrows(ApiException.class,()->transferTo(c,parentDemand(c),"10"));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_workshop_direct_transfer_items WHERE to_demand_id=?",Integer.class,parentDemand(c)));
    }

    @Test
    void returnedAndReleasedSlicesNeverRelabelAnotherConsumedSource() {
        proveReturnedSourceReleaseAndRestoration(false);
    }

    @org.junit.jupiter.params.ParameterizedTest
    @org.junit.jupiter.params.provider.ValueSource(booleans={false,true})
    void issuedMaterialReturnCarriesItsOriginalCostIntoAnotherMixedNormalPool(boolean laterInbound) {
        ManualFamily family=manualFamily("adv-return-cost-"+laterInbound);Case c=family.context();
        UUID raw=db.queryForObject("SELECT goods_id FROM production_material_demands WHERE execution_segment_id=?",UUID.class,c.childSegment());
        UUID destination=normalSibling(c,"adv-return-cost-normal-"+laterInbound);
        receiveAt(c,raw,destination,"10","99");
        var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
        fixture.loginAs(c.workerUser());
        var source=returns.sources(c.childPlan(),c.childSegment()).stream().filter(row->row.issuePostingId()!=null).findFirst().orElseThrow();
        var request=returns.submit(c.childPlan(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                c.childSegment(),"adv-cost-return-"+laterInbound,"真实原料余三件送正常仓",
                List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(source.issuePostingId(),new BigDecimal("3"))))).getFirst();
        fixture.loginAs(c.world().superAdminUserId());
        stock.confirmProductionMaterialReturn(request.documentId(),new com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest(destination,"adv-cost-confirm"));
        poolValue(destination,raw,"13","1020");
        qty("30",db.queryForObject("SELECT known_value_local FROM stock_value_events WHERE source_doc_id=? AND operation='POSITION_STORE'",BigDecimal.class,request.documentId()));
        if(laterInbound)receiveAt(c,raw,destination,"2","7");
        stock.reverse(request.documentId());
        poolValue(destination,raw,laterInbound?"12":"10",laterInbound?"1004":"990");
        qty("30",db.queryForObject("SELECT known_value_local FROM stock_value_events WHERE source_doc_id=? AND operation='POSITION_STORE_REVERSE'",BigDecimal.class,request.documentId()));
        qty("200",db.queryForObject("SELECT consumed_qty FROM stock_reservations WHERE id=(SELECT reservation_id FROM production_material_stock_postings WHERE id=?)",BigDecimal.class,source.issuePostingId()));
    }

    @org.junit.jupiter.params.ParameterizedTest
    @org.junit.jupiter.params.provider.ValueSource(booleans={false,true})
    void directSurplusCarriesActualSourceValueAndReversesBothTypedOrigins(boolean alreadyIssued) {
        ManualFamily family=manualFamily("adv-direct-cost-"+alreadyIssued);Case c=family.context();UUID[] target=family.first();
        UUID demand=db.queryForObject("SELECT id FROM production_material_demands WHERE execution_segment_id=?",UUID.class,c.childSegment());
        transferTo(c,target[2],"10");
        drainValue(c,List.of(c.child(),db.queryForObject("SELECT goods_id FROM production_material_demands WHERE id=?",UUID.class,demand)));
        // Current non-final output10 owns 10/200 of the true consumed cost100.
        poolValue(c.lineSide(),c.child(),"10","5");
        if(alreadyIssued)confirmRoute(target[0],target[1],"CONTINUOUS");
        UUID destination=normalSibling(c,"adv-direct-cost-normal-"+alreadyIssued);
        receiveAt(c,c.child(),destination,"10","99");
        var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
        fixture.loginAs(c.workerUser());
        var source=returns.sources(target[0],target[1]).stream().filter(row->alreadyIssued?row.issuePostingId()!=null:row.directTransferItemId()!=null).findFirst().orElseThrow();
        var request=returns.submit(target[0],new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                target[1],"adv-direct-cost-return-"+alreadyIssued,"余料送正常仓必须带原价",
                List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(source.issuePostingId(),new BigDecimal("3"),source.directTransferItemId())))).getFirst();
        fixture.loginAs(c.world().superAdminUserId());
        stock.confirmProductionMaterialReturn(request.documentId(),new com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest(destination,"adv-direct-cost-confirm-"+alreadyIssued));
        poolValue(destination,c.child(),"13","991.5");
        poolValue(c.lineSide(),c.child(),alreadyIssued?"0":"7",alreadyIssued?"0":"3.5");
        qty("1.5",db.queryForObject("SELECT known_value_local FROM stock_value_events WHERE source_doc_id=? AND operation='POSITION_STORE'",BigDecimal.class,request.documentId()));
        stock.reverse(request.documentId());
        poolValue(destination,c.child(),"10","990");
        poolValue(c.lineSide(),c.child(),alreadyIssued?"0":"10",alreadyIssued?"0":"5");
        qty(alreadyIssued?"10":"0",issued(target[2]));
        assertEquals(alreadyIssued?2:4,db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_id=?",Integer.class,request.documentId()));
    }

    private UUID normalSibling(Case c,String tag) {
        UUID id=UUID.randomUUID();db.update("INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",id,tag,tag,c.world().warehouseId());return id;
    }

    @Test
    void laterActualOutboundBlocksCostWithdrawalWithoutChangingThePrivateReturn() {
        ManualFamily family=manualFamily("adv-return-used-pool");Case c=family.context();
        UUID raw=db.queryForObject("SELECT goods_id FROM production_material_demands WHERE execution_segment_id=?",UUID.class,c.childSegment());
        UUID destination=normalSibling(c,"adv-return-used-normal");receiveAt(c,raw,destination,"10","99");
        var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
        fixture.loginAs(c.workerUser());
        var source=returns.sources(c.childPlan(),c.childSegment()).stream().filter(row->row.issuePostingId()!=null).findFirst().orElseThrow();
        var request=returns.submit(c.childPlan(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                c.childSegment(),"adv-used-return","正常仓私有退料三件",
                List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(source.issuePostingId(),new BigDecimal("3"))))).getFirst();
        fixture.loginAs(c.world().superAdminUserId());
        stock.confirmProductionMaterialReturn(request.documentId(),new com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest(destination,"adv-used-confirm"));
        var outbound=new StockDocSaveRequest();outbound.setDocType("OTHER_OUT");outbound.setWarehouseId(destination);outbound.setBillDate(BusinessTime.today());
        var line=new StockDocItemLine();line.setGoodsId(raw);line.setUnitId(c.world().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(BigDecimal.ONE);outbound.setItems(List.of(line));
        stock.approve(stock.create(outbound).getId());
        var before=db.queryForMap("SELECT node.id,node.quantity_basis,node.basis_value_local FROM stock_value_pools pool JOIN stock_value_nodes node ON node.id=pool.head_node_id WHERE pool.warehouse_id=? AND pool.goods_id=?",destination,raw);
        Throwable rejected=assertThrows(RuntimeException.class,()->stock.reverse(request.documentId()),"已实际按混合池出库的成本必须先处理真实后继");
        while(rejected.getCause()!=null)rejected=rejected.getCause();
        assertTrue(rejected.getMessage().contains("later actual stock consumption"),rejected.getMessage());
        assertEquals(before,db.queryForMap("SELECT node.id,node.quantity_basis,node.basis_value_local FROM stock_value_pools pool JOIN stock_value_nodes node ON node.id=pool.head_node_id WHERE pool.warehouse_id=? AND pool.goods_id=?",destination,raw));
        assertEquals(1,db.queryForObject("SELECT status FROM stock_documents WHERE id=?",Integer.class,request.documentId()));
        qty("3",db.queryForObject("SELECT SUM(reservation.qty-reservation.consumed_qty-reservation.released_qty) FROM stock_reservations reservation JOIN production_workshop_material_custody_moves move ON move.target_reservation_id=reservation.id JOIN production_material_return_request_items item ON item.id=move.request_item_id WHERE item.request_id=?",BigDecimal.class,request.documentId()));
    }

    @Test
    void manualMakePegCustodyIsConvertedOnceWhenItsOriginalTaskConfirmsTheRoute() {
        ManualFamily family=manualFamily("adv-legacy-custody");Case c=family.context();UUID[] target=family.first();
        transferTo(c,target[2],"10");
        var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
        fixture.loginAs(c.workerUser());
        var source=returns.sources(target[0],target[1]).stream().filter(row->row.directTransferItemId()!=null).findFirst().orElseThrow();
        var request=returns.submit(target[0],new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                target[1],"adv-legacy-custody-return","未领三件先送正常仓保存",
                List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(null,new BigDecimal("3"),source.directTransferItemId())))).getFirst();
        fixture.loginAs(c.world().superAdminUserId());
        stock.confirmProductionMaterialReturn(request.documentId(),new com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest(c.leaf(),"adv-legacy-custody-receive"));
        assertEquals("WAITING",status(target[1]));
        fixture.loginAs(c.workerUser());confirmRoute(target[0],target[1],"CONTINUOUS");
        // V710 起路线确认即把手工看管料自动投入(车间直送料会自动投入), 无需再走仓库领料;
        // 送正常仓保存的 3 件在路线确认时回到车间看管, 留待开工时投入。
        qty("7",issued(target[2]));
        qty("7",db.queryForObject("SELECT SUM(consumed_qty) FROM production_material_supply_pegs WHERE demand_id=?",BigDecimal.class,target[2]));
        qty("7",db.queryForObject("SELECT SUM(allocated_qty) FROM production_material_make_receipt_allocations WHERE demand_id=? AND status='EFFECTIVE'",BigDecimal.class,target[2]));
        qty("3",db.queryForObject("SELECT COALESCE(SUM(qty-consumed_qty-released_qty),0) FROM stock_reservations WHERE owner_type='WORKSHOP_CUSTODY' AND owner_id=? AND NOT is_deleted",BigDecimal.class,target[2]));
    }

    private void poolValue(UUID warehouse,UUID goods,String quantity,String value) {
        var pool=db.queryForMap("SELECT node.quantity_basis,node.basis_value_local FROM stock_value_pools pool JOIN stock_value_nodes node ON node.id=pool.head_node_id WHERE pool.warehouse_id=? AND pool.goods_id=? AND pool.color_id IS NULL",warehouse,goods);
        qty(quantity,(BigDecimal)pool.get("quantity_basis"));qty(value,(BigDecimal)pool.get("basis_value_local"));
    }

    private void drainValue(Case c,List<UUID> goods) {
        var operator=org.springframework.security.core.context.SecurityContextHolder.getContext();
        org.springframework.security.core.context.SecurityContextHolder.clearContext();
        try {InventoryValueWorkTestSupport.drain(beans.getBean(com.uten.imp.features.stock.valuation.InventoryValueWorkService.class),db,goods);}
        finally {org.springframework.security.core.context.SecurityContextHolder.setContext(operator);}
    }

    @Test
    void anEntireReturnedEarlierBatchCanRetireWithoutErasingItsReceiptHistory() {
        proveReturnedSourceReleaseAndRestoration(true);
    }

    private void proveReturnedSourceReleaseAndRestoration(boolean incremental) {
        ManualFamily family=manualFamily(incremental?"adv-retired-source":"adv-source-slices",false,true);
        Case c=family.context();UUID[] target=family.first();
        if(incremental)confirmRoute(target[0],target[1],"CONTINUOUS");
        UUID firstReport=transferTo(c,target[2],"5"),secondReport=transferTo(c,target[2],"5");
        if(!incremental)confirmRoute(target[0],target[1],"CONTINUOUS");
        var slices=db.queryForList("""
                SELECT allocation.id,allocation.stock_reservation_id,report.report_id
                FROM production_workshop_direct_source_allocations allocation
                JOIN production_workshop_direct_transfer_items transfer ON transfer.id=allocation.transfer_item_id
                JOIN production_daily_report_items report ON report.id=transfer.source_report_item_id
                JOIN stock_reservations reservation ON reservation.id=allocation.stock_reservation_id
                WHERE reservation.demand_id=? ORDER BY allocation.allocation_no
                """,target[2]);
        assertEquals(2,slices.size());
        var firstSlice=slices.stream().filter(row->firstReport.equals(row.get("report_id"))).findFirst().orElseThrow();
        var secondSlice=slices.stream().filter(row->secondReport.equals(row.get("report_id"))).findFirst().orElseThrow();
        UUID reservation=(UUID)firstSlice.get("stock_reservation_id");
        if(incremental)assertNotEquals(reservation,secondSlice.get("stock_reservation_id"));
        else assertEquals(reservation,secondSlice.get("stock_reservation_id"));
        UUID a=(UUID)firstSlice.get("id"),b=(UUID)secondSlice.get("id");
        sourceBalance(a,"5","5");sourceBalance(b,"5","5");
        var originalReceipts=db.queryForList("SELECT to_jsonb(allocation)::text FROM production_material_make_receipt_allocations allocation WHERE demand_id=? ORDER BY id",String.class,target[2]);
        List<String> plan=db.queryForList("EXPLAIN (ANALYZE,BUFFERS) SELECT id,received_qty,available_qty FROM v_workshop_direct_supply_lots WHERE to_demand_id=?",
                String.class,target[2]);
        System.out.println("V615_POINT_LOOKUP_EXPLAIN existing_lots="+db.queryForObject("SELECT count(*) FROM production_workshop_direct_transfer_items",Integer.class)
                +" matched_lots=2\n"+String.join("\n",plan));
        assertTrue(plan.stream().noneMatch(line->line.contains("WindowAgg")),"来源余额不得对全部历史做窗口聚合");
        var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
        fixture.loginAs(c.workerUser());
        segments.start(target[0],target[1],new SegmentTransitionRequest(version(target[1]),"adv-source-return-start"));
        UUID originalIssue=db.queryForObject("SELECT stock_posting_id FROM production_workshop_direct_source_events WHERE source_allocation_id=? AND event_type='ISSUE'",UUID.class,a);
        var source=returns.sources(target[0],target[1]).stream().filter(row->row.issuePostingId().equals(originalIssue)).findFirst().orElseThrow();
        var returned=returns.submit(target[0],new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                target[1],"adv-source-return-"+target[1],"精确来源退料",
                List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(source.issuePostingId(),new BigDecimal("5"))))).getFirst();
        fixture.loginAs(c.world().superAdminUserId());
        stock.confirmProductionMaterialReturn(returned.documentId(),new com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest(c.leaf(),"adv-source-normal-"+target[1]));
        UUID returnDocument=returned.documentId();
        assertEquals(c.leaf(),db.queryForObject("SELECT warehouse_id FROM stock_documents WHERE id=?",UUID.class,returnDocument));
        UUID normalAllocation=db.queryForObject("SELECT move.target_allocation_id FROM production_workshop_material_custody_moves move JOIN production_material_return_request_items item ON item.id=move.request_item_id WHERE item.request_id=?",UUID.class,returnDocument);
        sourceBalance(a,"0","0");sourceBalance(b,"5","5");sourceBalance(normalAllocation,"5","0");
        qty("0",db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,c.lineSide(),c.child()));
        qty("5",db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,c.leaf(),c.child()));
        // Retire the remaining unfulfilled source commitment before early final.
        // Keep its identity and already converted10; no other source can replace it.
        db.update("UPDATE production_material_supply_pegs SET released_qty=allocated_qty-consumed_qty,status='DONE',lock_version=lock_version+1 WHERE demand_id=?",target[2]);
        fixture.loginAs(c.workerUser());
        UUID finalReport=reportParentFinal(c,"5");
        fixture.loginAs(c.world().superAdminUserId());
        UUID finished=acceptWarehouseReport(c,finalReport,"5");
        assertEquals("COMPLETED",status(target[1]));
        sourceBalance(a,"0","0");sourceBalance(b,"5","5");
        assertEquals(originalReceipts,db.queryForList("SELECT to_jsonb(allocation)::text FROM production_material_make_receipt_allocations allocation WHERE demand_id=? ORDER BY id",String.class,target[2]),
                "真实退料和完成释放不得改写原receipt兑现记录");
        if(incremental) {
            qty("0",db.queryForObject("SELECT consumed_qty FROM stock_reservations WHERE id=?",BigDecimal.class,reservation));
            qty("0",db.queryForObject("SELECT qty-released_qty FROM stock_reservations WHERE id=?",BigDecimal.class,reservation));
            assertEquals(1,db.queryForObject("SELECT status FROM stock_reservations WHERE id=?",Integer.class,reservation));
            var newFunding=assertThrows(org.springframework.dao.DataAccessException.class,()->db.update("""
                    INSERT INTO production_material_make_receipt_allocations
                    SELECT (jsonb_populate_record(NULL::production_material_make_receipt_allocations,
                        to_jsonb(original)||jsonb_build_object('id',gen_random_uuid(),'idempotency_key','forged-retired-'||gen_random_uuid()))).*
                    FROM production_material_make_receipt_allocations original WHERE reservation_id=? LIMIT 1
                    """,reservation));
            assertTrue(newFunding.getMostSpecificCause().getMessage().contains("live unconsumed formal reservation"));
        }
        var costGoods=db.queryForList("SELECT DISTINCT goods_id FROM production_material_demands WHERE plan_id IN (?,?) UNION SELECT ?::uuid UNION SELECT ?::uuid",
                UUID.class,c.plan(),c.childPlan(),c.parent(),c.child());
        var operator=org.springframework.security.core.context.SecurityContextHolder.getContext();
        org.springframework.security.core.context.SecurityContextHolder.clearContext();
        try {InventoryValueWorkTestSupport.drain(beans.getBean(com.uten.imp.features.stock.valuation.InventoryValueWorkService.class),db,costGoods);}
        finally {org.springframework.security.core.context.SecurityContextHolder.setContext(operator);}
        stock.reverseFinishedInbound(finished);
        // The original MOVE proves exactly which released technical source
        // returns to WIP; no raw reservation restoration or technical receipt.
        sourceBalance(a,"0","0");sourceBalance(b,"5","5");sourceBalance(normalAllocation,"0","0");
        stock.reverse(returnDocument);
        sourceBalance(a,"5","5");sourceBalance(b,"5","5");
        UUID wrongCounter=db.queryForObject("SELECT id FROM production_workshop_direct_source_events WHERE source_allocation_id=? AND event_type='ISSUE'",UUID.class,b);
        UUID returnedPosting=db.queryForObject("SELECT stock_posting_id FROM production_workshop_direct_source_events WHERE source_allocation_id=? AND event_type='GOOD_RETURN' ORDER BY event_no DESC LIMIT 1",UUID.class,a);
        var failure=assertThrows(org.springframework.dao.DataAccessException.class,()->db.update("""
                INSERT INTO production_workshop_direct_source_events(source_allocation_id,stock_posting_id,counter_event_id,event_type,qty_base)
                VALUES(?,?,?,'GOOD_RETURN',1)
                """,a,returnedPosting,wrongCounter));
        assertEquals("23514",assertInstanceOf(java.sql.SQLException.class,failure.getMostSpecificCause()).getSQLState());
        assertTrue(failure.getMostSpecificCause().getMessage().contains("exact original allocation"));
    }

    private void sourceBalance(UUID allocation,String held,String issued) {
        var balance=db.queryForMap("SELECT effective_qty,net_issued_qty FROM v_workshop_direct_source_allocations WHERE id=?",allocation);
        qty(held,(BigDecimal)balance.get("effective_qty"));qty(issued,(BigDecimal)balance.get("net_issued_qty"));
    }

    @Test
    void ordinaryTransfersCannotRemoveDedicatedWorkshopSourcesIncludingOldDrafts() {
        ManualFamily family=manualFamily("adv-physical-boundary");Case c=family.context();
        transferTo(c,family.first()[2],"10");
        fixture.loginAs(c.world().superAdminUserId());
        UUID other=UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",
                other,"ADV-NORMAL-"+other,"正常收料子仓",c.world().warehouseId());
        receive(c,c.child(),c.leaf(),"5");
        UUID normal=transferDocument(c,c.leaf(),other,"5");stock.approve(normal);
        qty("5",db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,other,c.child()));
        UUID oldDraft=transferDocument(c,other,c.leaf(),"1");
        // A pre-upgrade draft may have a technical source even though new selectors exclude it.
        db.update("UPDATE stock_documents SET warehouse_id=? WHERE id=?",c.lineSide(),oldDraft);
        var rejected=assertThrows(ApiException.class,()->stock.approve(oldDraft));
        assertTrue(rejected.getMessage().contains("不能以普通调拨"));
        UUID item=db.queryForObject("SELECT id FROM stock_document_items WHERE doc_id=?",UUID.class,oldDraft);
        var movements=beans.getBean(com.uten.imp.features.stock.StockService.class);
        var tx=new org.springframework.transaction.support.TransactionTemplate(beans.getBean(org.springframework.transaction.PlatformTransactionManager.class));
        var denied=assertThrows(RuntimeException.class,()->tx.execute(status->movements.recordMovement(new com.uten.imp.features.stock.StockService.MovementRequest(
                java.time.OffsetDateTime.now(),(short)8,"STOCK_DOC",oldDraft,item,c.child(),null,c.lineSide(),(short)-1,
                BigDecimal.ONE,c.world().unitId(),BigDecimal.ONE,null,"不能绕过技术位来源守卫",null))));
        Throwable cause=denied;while(cause.getCause()!=null)cause=cause.getCause();
        assertTrue(cause.getMessage().contains("workshop_direct_physical_provenance")
                ||cause.getMessage().contains("Technical workshop stock"),cause.getMessage());
        qty("10",db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,c.lineSide(),c.child()));
    }

    @Test
    void ordinaryMakeReceiptInTheActualLeafWakesItsLegacyMainWarehouseDemand() {
        ManualFamily family=manualFamily("adv-receipt-leaf");Case c=family.context();UUID[] target=family.first();
        confirmRoute(target[0],target[1],"CONTINUOUS");assertEquals("WAITING",status(target[1]));
        UUID report=reportToWarehouse(c,"10");fixture.loginAs(c.world().superAdminUserId());
        acceptWarehouseReport(c,report,"10");
        assertEquals("READY",status(target[1]),"真实子叶仓收货应立即唤醒逻辑主仓范围的原需求");
        qty("10",db.queryForObject("SELECT COALESCE(SUM(qty-released_qty),0) FROM stock_reservations WHERE demand_id=?",BigDecimal.class,target[2]));
        qty("0",issued(target[2]));
        assertEquals(c.leaf(),db.queryForObject("SELECT warehouse_id FROM stock_reservations WHERE demand_id=?",UUID.class,target[2]));
    }

    private UUID acceptWarehouseReport(Case c,UUID report,String quantity) {
        UUID reportItem=db.queryForObject("SELECT id FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted",UUID.class,report);
        beans.getBean(com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService.class).register(report,
                new com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationRequest(
                        "adv-arrival-"+report,c.leaf(),List.of(new com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationItemRequest(
                                reportItem,"实际普通叶仓")),null));
        UUID inspection=db.queryForObject("SELECT id FROM production_fqc_inspections WHERE source_report_item_id=?",UUID.class,reportItem);
        beans.getBean(com.uten.imp.features.production.quality.ProductionFqcInspectionService.class).decide(inspection,
                new com.uten.imp.features.production.quality.ProductionFqcContracts.DecisionRequest("PASS",new BigDecimal(quantity),null,null,null,"adv-quality-"+report));
        UUID receipt=db.queryForObject("""
                SELECT DISTINCT document.id FROM stock_documents document
                JOIN stock_document_items item ON item.doc_id=document.id
                JOIN production_daily_report_items source ON source.id=item.source_daily_report_item_id
                WHERE source.report_id=? AND document.doc_type='FINISHED_IN' AND NOT document.is_deleted
                """,UUID.class,report);
        org.springframework.test.util.ReflectionTestUtils.invokeMethod(fixture,"confirmFinishedInboundFully",receipt);
        return receipt;
    }

    @Test
    void splitProducingSegmentsShareTheirOneMakePegResponsibility() {
        ManualFamily family=manualFamily("adv-producer-split",true);Case c=family.context();UUID[] target=family.first();
        UUID otherSegment=db.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=? AND id<>? AND NOT is_deleted",UUID.class,c.childPlan(),c.childSegment());
        fixture.loginAs(c.workerUser());confirmRoute(c.childPlan(),otherSegment,"FULL_KIT");requestAndIssue(c,otherSegment);
        segments.start(c.childPlan(),otherSegment,new SegmentTransitionRequest(version(otherSegment),"adv-start-other-producer"));
        // A valid partially released supply commitment: the demand still needs100,
        // but this source plan item now owns only50. Keep the original peg identity.
        db.update("UPDATE production_material_supply_pegs SET released_qty=50,lock_version=lock_version+1 WHERE demand_id=? AND supply_type='PRODUCTION_PLAN_ITEM'",target[2]);
        transferTo(c,target[2],"40");
        Case other=new Case(c.world(),c.parent(),c.child(),c.secondMaterial(),c.plan(),c.segment(),c.childPlan(),otherSegment,
                c.workshop(),c.worker(),c.workerUser(),c.leaf(),c.lineSide());
        qty("10",db.queryForObject("SELECT fn_workshop_direct_remaining_for_source(?,?)",BigDecimal.class,otherSegment,target[2]));
        var direct=beans.getBean(com.uten.imp.features.production.directtransfer.ProductionWorkshopDirectTransferService.class);
        var candidate=direct.candidates(otherSegment,c.child(),null).candidates().stream().filter(row->row.demandId().equals(target[2])).findFirst().orElseThrow();
        qty("10",candidate.remainingQty());
        // V707 起超额直送不再当场硬拒(转入超产申请/审批口径), 原边界断言退役;
        // 仍锁定共享责任主线: 许可内 15 正常直送, 随后原段共享额度耗尽归零。
        transferTo(other,target[2],"15");
        qty("0",db.queryForObject("SELECT fn_workshop_direct_remaining_for_source(?,?)",BigDecimal.class,c.childSegment(),target[2]));
    }

    private UUID transferDocument(Case c,UUID from,UUID to,String quantity) {
        var line=new StockDocItemLine();line.setGoodsId(c.child());line.setQty(new BigDecimal(quantity));
        line.setUnitId(c.world().unitId());line.setUnitRate(BigDecimal.ONE);
        var request=new StockDocSaveRequest();request.setDocType("TRANSFER");request.setBillDate(BusinessTime.today());
        request.setWarehouseId(from);request.setToWarehouseId(to);request.setItems(List.of(line));
        return stock.create(request).getId();
    }

    private record ManualFamily(Case context,UUID[] first,UUID[] second) {}
    private ManualFamily manualFamily(String tag) {
        return manualFamily(tag,false);
    }

    private ManualFamily manualFamily(String tag,boolean splitProducer) {
        return manualFamily(tag,splitProducer,false);
    }

    private ManualFamily manualFamily(String tag,boolean splitProducer,boolean singleTarget) {
        Case original=create(tag,false);
        fixture.loginAs(original.world().superAdminUserId());
        UUID raw=db.queryForObject("SELECT component_goods_id FROM goods_bom_items WHERE goods_id=? AND NOT is_deleted",UUID.class,original.child());
        poolValue(original.leaf(),raw,"0","0");
        receive(original,raw,original.leaf(),"200");
        poolValue(original.leaf(),raw,"200","2000");
        UUID parent=manualPlan(original,original.parent(),new BigDecimal("200"));
        var parentPackage=manualPackage(original,parent,tag+"-parent",singleTarget?List.of(new BigDecimal("200")):List.of(new BigDecimal("100"),new BigDecimal("100")));
        UUID producer=parentPackage.subplans().getFirst().planId();
        beans.getBean(com.uten.imp.features.production.plan.ProductionPlanService.class).approve(producer);
        var producerPackage=manualPackage(original,producer,tag+"-child",splitProducer?List.of(new BigDecimal("100"),new BigDecimal("100")):List.of(new BigDecimal("200")));
        UUID childSegment=producerPackage.executionSegments().getFirst().segmentId();
        UUID firstSegment=parentPackage.executionSegments().get(0).segmentId(),secondSegment=parentPackage.executionSegments().get(singleTarget?0:1).segmentId();
        confirmRoute(parent,firstSegment,"FULL_KIT");if(!firstSegment.equals(secondSegment))confirmRoute(parent,secondSegment,"FULL_KIT");
        Case c=new Case(original.world(),original.parent(),original.child(),null,parent,firstSegment,
                producer,childSegment,original.workshop(),original.worker(),original.workerUser(),original.leaf(),original.lineSide());
        fixture.loginAs(c.workerUser());confirmRoute(c.childPlan(),c.childSegment(),"FULL_KIT");
        requestAndIssue(c,c.childSegment());
        segments.start(c.childPlan(),c.childSegment(),new SegmentTransitionRequest(version(c.childSegment()),"adv-source-start"));
        UUID[] first=new UUID[]{parent,firstSegment,db.queryForObject("SELECT id FROM production_material_demands WHERE execution_segment_id=? AND goods_id=?",UUID.class,firstSegment,c.child())};
        UUID[] second=new UUID[]{parent,secondSegment,db.queryForObject("SELECT id FROM production_material_demands WHERE execution_segment_id=? AND goods_id=?",UUID.class,secondSegment,c.child())};
        assertEquals(singleTarget?1:2,db.queryForObject("SELECT COUNT(*) FROM production_material_supply_pegs WHERE demand_id IN (?,?) AND supply_type='PRODUCTION_PLAN_ITEM'",Integer.class,first[2],second[2]));
        return new ManualFamily(c,first,second);
    }

    private UUID manualPlan(Case c,UUID product,BigDecimal quantity) {
        fixture.loginAs(c.world().superAdminUserId());
        UUID order=fixture.createApprovedOrder(c.world(),product,quantity.toPlainString(),"100");
        var orderItem=db.queryForMap("SELECT item.id,header.bill_no FROM sales_order_items item JOIN sales_orders header ON header.id=item.order_id WHERE item.order_id=?",order);
        var line=new com.uten.imp.features.production.plan.dto.PlanItemLine();
        line.setGoodsId(product);line.setUnitId(c.world().unitId());line.setUnitRate(BigDecimal.ONE);
        line.setSalesOrderItemId((UUID)orderItem.get("id"));line.setSalesOrderNo((String)orderItem.get("bill_no"));
        line.setQty(quantity);line.setOqty(quantity);
        var save=new com.uten.imp.features.production.plan.dto.PlanSaveRequest();save.setBillDate(BusinessTime.today());
        save.setDepartmentId(c.workshop());save.setWorkerId(c.worker());save.setItems(List.of(line));
        var plans=beans.getBean(com.uten.imp.features.production.plan.ProductionPlanService.class);
        UUID plan=plans.create(save).getId();plans.approve(plan);return plan;
    }

    private com.uten.imp.features.production.mrp.PlanningPackageResult manualPackage(Case c,UUID plan,String tag,List<BigDecimal> quantities) {
        fixture.loginAs(c.world().superAdminUserId());
        var packages=beans.getBean(com.uten.imp.features.production.mrp.ProductionPlanningPackageService.class);
        var preview=packages.preview(plan,c.world().warehouseId());var proposal=preview.executionSegments().getFirst();
        var request=new com.uten.imp.features.production.mrp.GeneratePlanningPackageRequest();
        request.setWarehouseId(c.world().warehouseId());request.setIdempotencyKey(tag+"-package");
        request.setPreviewFingerprint(preview.fingerprint());request.setGeneratePurchaseRequest(true);
        var parts=new java.util.ArrayList<com.uten.imp.features.production.mrp.GeneratePlanningPackageRequest.ExecutionSegment>();
        int index=0;
        for(BigDecimal quantity:quantities) {
            var part=new com.uten.imp.features.production.mrp.GeneratePlanningPackageRequest.ExecutionSegment();
            part.setClientSegmentKey(tag+"-part-"+(++index));part.setSourcePlanItemId(proposal.sourcePlanItemId());
            part.setRequestedStatus(proposal.suggestedStatus());part.setPlannedQty(quantity);part.setBomFingerprint(proposal.bomFingerprint());
            part.setWorkshopDepartmentId(c.workshop());part.setResponsibleEmployeeId(c.worker());parts.add(part);
        }
        request.setSegments(parts);return packages.confirm(plan,request);
    }

    private void requestAndIssue(Case c,UUID segmentId) {
        fixture.loginAs(c.workerUser());
        var items=List.of(new ProductionDrawRequest.Item(segmentId,version(segmentId)));
        var preview=drawRequests.preview(new ProductionDrawRequest.PreviewRequest(items));
        var result=drawRequests.submit(new ProductionDrawRequest.SubmitRequest(items,"adv-draw-"+segmentId,preview.fingerprint()));
        fixture.loginAs(c.world().superAdminUserId());
        assertEquals(Boolean.TRUE,db.queryForObject("""
                SELECT bool_and(fn_warehouse_same_main(document.warehouse_id,demand.warehouse_id)
                    AND document.warehouse_id<>demand.warehouse_id
                    AND EXISTS(SELECT 1 FROM stock_reservations held WHERE held.demand_id=demand.id
                        AND held.warehouse_id=document.warehouse_id AND held.qty-held.released_qty>0))
                FROM production_planning_package_document_items mapping
                JOIN stock_documents document ON document.id=mapping.document_id
                JOIN production_material_demands demand ON demand.id=mapping.demand_id
                WHERE demand.execution_segment_id=? AND mapping.document_type='DRAW'
                """,Boolean.class,segmentId),"旧手工任务仍保留真实叶仓和唯一正式预留，只跨同一主仓下叶仓");
        for(UUID document:result.documentIds()) {
            var issue=new com.uten.imp.features.stock.dto.StockDocIssueRequest();issue.setIdempotencyKey("adv-issue-"+document);
            issue.setLines(preview.lines().stream().filter(line->line.drawId().equals(document)).map(line->{
                var item=new com.uten.imp.features.stock.dto.StockDocIssueRequest.Line();item.setItemId(line.drawItemId());item.setQty(line.qty());return item;
            }).toList());stock.approveAndIssue(document,issue);
        }
        fixture.loginAs(c.workerUser());
    }

    private UUID[] manualTarget(Case c,String tag) { return manualTask(c,tag,c.parent()); }

    private UUID[] manualTask(Case c,String tag,UUID product) {
        fixture.loginAs(c.world().superAdminUserId());
        UUID order=fixture.createApprovedOrder(c.world(),product,"100","100");
        var orderItem=db.queryForMap("SELECT item.id,header.bill_no FROM sales_order_items item JOIN sales_orders header ON header.id=item.order_id WHERE item.order_id=?",order);
        var line=new com.uten.imp.features.production.plan.dto.PlanItemLine();
        line.setGoodsId(product);line.setUnitId(c.world().unitId());line.setUnitRate(BigDecimal.ONE);
        line.setSalesOrderItemId((UUID)orderItem.get("id"));line.setSalesOrderNo((String)orderItem.get("bill_no"));
        line.setQty(new BigDecimal("100"));line.setOqty(new BigDecimal("100"));
        var save=new com.uten.imp.features.production.plan.dto.PlanSaveRequest();
        save.setBillDate(BusinessTime.today());save.setDepartmentId(c.workshop());save.setWorkerId(c.worker());save.setItems(List.of(line));
        var plans=beans.getBean(com.uten.imp.features.production.plan.ProductionPlanService.class);
        UUID plan=plans.create(save).getId();plans.approve(plan);
        var packages=beans.getBean(com.uten.imp.features.production.mrp.ProductionPlanningPackageService.class);
        var preview=packages.preview(plan,c.world().warehouseId());
        var request=new com.uten.imp.features.production.mrp.GeneratePlanningPackageRequest();
        request.setWarehouseId(c.world().warehouseId());request.setIdempotencyKey(tag+"-package");
        request.setPreviewFingerprint(preview.fingerprint());request.setGeneratePurchaseRequest(true);
        var proposal=preview.executionSegments().getFirst();
        var segment=new com.uten.imp.features.production.mrp.GeneratePlanningPackageRequest.ExecutionSegment();
        segment.setClientSegmentKey(tag+"-segment");segment.setSourcePlanItemId(proposal.sourcePlanItemId());
        segment.setRequestedStatus(proposal.suggestedStatus());segment.setPlannedQty(proposal.plannedQty());
        segment.setBomFingerprint(proposal.bomFingerprint());segment.setWorkshopDepartmentId(c.workshop());
        segment.setResponsibleEmployeeId(c.worker());request.setSegments(List.of(segment));
        var result=packages.confirm(plan,request);UUID execution=result.executionSegments().getFirst().segmentId();
        confirmRoute(plan,execution,"FULL_KIT");
        assertNull(db.queryForObject("SELECT material_analysis_id FROM production_plans WHERE id=?",UUID.class,plan));
        return new UUID[]{plan,execution,db.queryForObject("SELECT id FROM production_material_demands WHERE execution_segment_id=?",UUID.class,execution)};
    }

    private BigDecimal issued(UUID demand) {
        return db.queryForObject("SELECT COALESCE(SUM(CASE WHEN posting_type='ISSUE' THEN qty_base WHEN posting_type='ISSUE_REVERSE' THEN -qty_base ELSE 0 END),0) FROM production_material_stock_postings WHERE demand_id=?",BigDecimal.class,demand);
    }

    private UUID transferTo(Case c,UUID demand,String quantity) {
        return reportTo(c,demand,quantity);
    }

    private UUID reportToWarehouse(Case c,String quantity) {
        return reportTo(c,null,quantity);
    }

    private UUID reportParentFinal(Case c,String quantity) {
        var report=new DailyReportSaveRequest();report.setIdempotencyKey("adv-parent-final-"+UUID.randomUUID());
        report.setBillDate(BusinessTime.today());report.setWarehouseId(c.leaf());report.setDepartmentId(c.workshop());report.setWorkerIds(List.of(c.worker()));
        var item=new DailyReportItemLine();item.setLineNo(1);item.setExecutionSegmentId(c.segment());
        item.setPlanItemId(db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",UUID.class,c.segment()));
        item.setExecutionSegmentSalesAllocationId(db.queryForObject("SELECT id FROM execution_segment_sales_allocations WHERE execution_segment_id=?",UUID.class,c.segment()));
        item.setSalesOrderItemId(db.queryForObject("SELECT sales_order_item_id FROM execution_segment_sales_allocations WHERE execution_segment_id=?",UUID.class,c.segment()));
        item.setGoodsId(c.parent());item.setUnitId(c.world().unitId());item.setUnitRate(BigDecimal.ONE);item.setQty(new BigDecimal(quantity));
        item.setIsFinal(true);item.setDestination("WAREHOUSE");report.setItems(List.of(item));
        report.setMaterialLines(WorkshopMaterialFlowTestSupport.materialUse(db,c.segment(),item.getQty()));
        UUID reportId=reports.create(report).getId();reports.approve(reportId, DailyReportApproveRequests.freshKey());return reportId;
    }

    private UUID reportTo(Case c,UUID demand,String quantity) {
        fixture.loginAs(c.workerUser());
        var report=new DailyReportSaveRequest();report.setIdempotencyKey("adv-report-"+UUID.randomUUID());
        report.setBillDate(BusinessTime.today());report.setWarehouseId(c.leaf());report.setDepartmentId(c.workshop());report.setWorkerIds(List.of(c.worker()));
        var item=new DailyReportItemLine();item.setLineNo(1);item.setExecutionSegmentId(c.childSegment());
        item.setPlanItemId(db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",UUID.class,c.childSegment()));
        item.setGoodsId(c.child());item.setUnitId(c.world().unitId());item.setUnitRate(BigDecimal.ONE);item.setQty(new BigDecimal(quantity));
        var allocations=db.queryForList("SELECT id FROM execution_segment_sales_allocations WHERE execution_segment_id=?",UUID.class,c.childSegment());
        if(allocations.size()==1)item.setExecutionSegmentSalesAllocationId(allocations.getFirst());
        item.setDestination(demand==null?"WAREHOUSE":"WORKSHOP");item.setDirectTransferDemandId(demand);report.setItems(List.of(item));
        report.setMaterialLines(WorkshopMaterialFlowTestSupport.materialUse(db,c.childSegment(),item.getQty()));
        UUID reportId=reports.create(report).getId();reports.approve(reportId, DailyReportApproveRequests.freshKey());return reportId;
    }

    // ===================== 夹具 =====================

    private record Case(
            FullChainEndToEndTest.World world,
            UUID parent, UUID child, UUID secondMaterial,
            UUID plan, UUID segment,
            UUID childPlan, UUID childSegment,
            UUID workshop, UUID worker, UUID workerUser,
            UUID leaf, UUID lineSide) {
    }

    /** 父件→自制子件→有实收/实发证据的原料；可选第二种父件采购输入。 */
    private Case create(String tag, boolean withBuyMaterial) {
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID parent = UUID.randomUUID(), child = UUID.randomUUID();
        UUID secondMaterial = withBuyMaterial ? UUID.randomUUID() : null;
        fixture.insertGoods(parent, "P-" + tag, "直送父件-" + tag, "自制", w.unitId(), w.unitLegacy());
        fixture.insertGoods(child, "CL-" + tag, "直送子件-" + tag, "自制", w.unitId(), w.unitLegacy());
        fixture.insertBom(parent, child, "1");
        UUID raw=UUID.randomUUID();fixture.insertGoods(raw,"RAW-"+tag,"直送实际原料","采购",w.unitId(),w.unitLegacy());fixture.insertBom(child,raw,"1");
        if (withBuyMaterial) {
            fixture.insertGoods(secondMaterial, "MAT-" + tag, "仓库子件-" + tag, "采购", w.unitId(), w.unitLegacy());
            fixture.insertBom(parent, secondMaterial, "1");
        }
        UUID production = db.queryForObject("SELECT id FROM departments WHERE code='DEPT_PROD'", UUID.class);
        UUID workshop = UUID.randomUUID(), worker = UUID.randomUUID();
        db.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES(?,?,?,?,'二级班组')",
                workshop, "W-" + tag, "直送车间-" + tag, production);
        db.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')
                """, worker, "DT-WORKER-" + tag, "直送负责人-" + tag, workshop);
        UUID workerUser = fixture.createUserWithPerms(w, "dt-worker-" + tag,
                "production_execution:view", "production_execution:start",
                "production_daily_report:view", "production_daily_report:create",
                "production_daily_report:approve", "production_direct_transfer:approve");
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",
                workshop, workerUser);
        UUID leaf = UUID.randomUUID(), lineSide = UUID.randomUUID();
        db.update("""
                INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable)
                VALUES(?,?,?,?,'使用',TRUE)
                """, leaf, "SUB-" + tag, "普通子仓-" + tag, w.warehouseId());
        db.update("""
                INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable,is_line_side,workshop_department_id)
                VALUES(?,?,?,?,'使用',TRUE,TRUE,?)
                """, lineSide, "LS-" + tag, "线边仓-" + tag, w.warehouseId(), workshop);
        fixture.loginAs(w.superAdminUserId());

        UUID order = fixture.createApprovedOrder(w, parent, "100", "100");
        UUID orderItem = db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?", UUID.class, order);
        var view = analyses.preview(new PreviewRequest(null, null, null, w.warehouseId(),
                "preview-" + tag, List.of(new PreviewItem("SALES_ORDER_ITEM", orderItem,
                null, null, null, null, null, BusinessTime.today().plusDays(10), new BigDecimal("100")))));
        analyses.saveRoutes(view.analysisId(), new RouteRequest(view.version(), view.fingerprint(),
                "routes-" + tag, view.flatMaterials().stream()
                        .map(row -> new RouteDecision(row.materialLineId(), row.actionGroupKey(),
                                row.goodsId().equals(parent) || row.goodsId().equals(child) ? "MAKE" : "BUY", null))
                        .toList()));
        WorkshopMaterialFlowTestSupport.receiveFreeInput(stock,w,leaf,raw,new BigDecimal("100"));
        view = analyses.detail(view.analysisId());
        UUID childLineId = view.flatMaterials().stream()
                .filter(row -> row.goodsId().equals(child)).findFirst().orElseThrow().materialLineId();
        var childResult = commands.issueWorkshopPlans(view.analysisId(), new IssueWorkshopPlansRequest(
                view.version(), view.fingerprint(), "child-" + tag, w.warehouseId(),
                BusinessTime.today(), BusinessTime.today().plusDays(10), true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                        childLineId, null, new BigDecimal("100"),
                        BusinessTime.today(), BusinessTime.today().plusDays(10),
                        workshop, null, worker, null, null))));
        UUID childPlan = childResult.plans().getFirst().planId();
        UUID childSegment = childResult.plans().getFirst().segmentIds().getFirst();
        assertEquals("READY", status(childSegment), "真实原料已预留，仍须发料才能开工");
        view = analyses.detail(view.analysisId());
        var rootResult = commands.issueWorkshopPlans(view.analysisId(), new IssueWorkshopPlansRequest(
                view.version(), view.fingerprint(), "root-" + tag, w.warehouseId(),
                BusinessTime.today(), BusinessTime.today().plusDays(10), true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                        null, view.products().getFirst().analysisLineId(), new BigDecimal("100"),
                        BusinessTime.today(), BusinessTime.today().plusDays(10),
                        workshop, null, worker, null, null))));
        UUID plan = rootResult.plans().getFirst().planId();
        UUID segment = db.queryForObject(
                "SELECT id FROM production_execution_segments WHERE plan_id=? AND status='WAITING'", UUID.class, plan);
        confirmRoute(plan,segment,"FULL_KIT");
        confirmRoute(childPlan, childSegment, "FULL_KIT");
        WorkshopMaterialFlowTestSupport.issue(db,drawRequests,stock,childSegment);
        fixture.loginAs(workerUser);
        segments.start(childPlan, childSegment,
                new SegmentTransitionRequest(version(childSegment), "dt-child-start-" + childSegment));
        return new Case(w, parent, child, secondMaterial, plan, segment, childPlan, childSegment,
                workshop, worker, workerUser, leaf, lineSide);
    }

    /** 子件报工选「转下一道工序」，把产出直送给父件对本子件的需求。 */
    private void transfer(Case c, String quantity) {
        fixture.loginAs(c.workerUser());
        var report = new DailyReportSaveRequest();
        report.setIdempotencyKey("dt-report-" + c.segment() + "-" + quantity);
        report.setBillDate(BusinessTime.today());
        report.setWarehouseId(c.leaf());
        report.setDepartmentId(c.workshop());
        report.setWorkerIds(List.of(c.worker()));
        var item = new DailyReportItemLine();
        item.setLineNo(1);
        item.setExecutionSegmentId(c.childSegment());
        item.setPlanItemId(db.queryForObject(
                "SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",
                UUID.class, c.childSegment()));
        item.setGoodsId(c.child());
        item.setUnitId(c.world().unitId());
        item.setUnitRate(BigDecimal.ONE);
        item.setQty(new BigDecimal(quantity));
        item.setIsFinal(false);
        item.setDestination("WORKSHOP");
        item.setDirectTransferDemandId(parentDemand(c));
        report.setItems(List.of(item));
        report.setMaterialLines(WorkshopMaterialFlowTestSupport.materialUse(db,c.childSegment(),item.getQty()));
        reports.approve(reports.create(report).getId(), DailyReportApproveRequests.freshKey());
    }

    private void receive(Case c, UUID goods, UUID warehouse, String quantity) {
        receiveAt(c,goods,warehouse,quantity,"10");
    }

    private void receiveAt(Case c, UUID goods, UUID warehouse, String quantity,String price) {
        fixture.loginAs(c.world().superAdminUserId());
        var request = new StockDocSaveRequest();
        request.setDocType("OTHER_IN");
        request.setWarehouseId(warehouse);
        request.setBillDate(BusinessTime.today());
        var line = new StockDocItemLine();
        line.setGoodsId(goods);
        line.setUnitId(c.world().unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(quantity));
        line.setPrice(new BigDecimal(price));
        line.setAmountOriginal(line.getQty().multiply(line.getPrice()));
        line.setAmountLocal(line.getAmountOriginal());
        request.setItems(List.of(line));
        stock.approve(stock.create(request).getId());
    }

    private UUID parentDemand(Case c) {
        return db.queryForObject(
                "SELECT id FROM production_material_demands WHERE execution_segment_id=? AND goods_id=?",
                UUID.class, c.segment(), c.child());
    }

    private java.util.Map<String, Object> drawOf(UUID segmentId) {
        return db.queryForMap("""
                SELECT document.warehouse_id AS warehouse_id, document.status AS status,
                       document.is_closed AS closed,
                       sum(item.issued_qty) AS issued
                FROM production_planning_package_documents mapping
                JOIN stock_documents document ON document.id=mapping.document_id
                JOIN stock_document_items item ON item.doc_id=document.id AND NOT item.is_deleted
                WHERE mapping.execution_segment_id=? AND mapping.document_type='DRAW'
                GROUP BY document.warehouse_id, document.status, document.is_closed
                """, segmentId);
    }

    /** 「审核并出库」后的终态：已审(1)+closed+足额 issued_qty。 */
    private static void assertAutoIssued(java.util.Map<String, Object> draw, String qty) {
        assertEquals(1, ((Number) draw.get("status")).intValue(), "直送领料单应已自动审核");
        assertEquals(Boolean.TRUE, draw.get("closed"), "直送领料单应已自动出库结清");
        qty(qty, (BigDecimal) draw.get("issued"));
    }

    private int drawRequestCount(UUID segmentId) {
        return db.queryForObject(
                "SELECT count(*) FROM production_execution_segment_events WHERE execution_segment_id=? AND action='DRAW_REQUEST'",
                Integer.class, segmentId);
    }

    /** V599 / ADR-091：开工前先确认生产路线——未确认路线时开工侧动作被服务端拒绝。 */
    private void confirmRoute(UUID planId, UUID segmentId, String route) {
        segments.confirmRoute(planId, segmentId,
                new com.uten.imp.features.production.execution.SegmentRouteConfirmRequest(
                        version(segmentId), "route-" + route + "-" + segmentId, route));
    }

    private long version(UUID id) {
        return db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?", Long.class, id);
    }

    private String status(UUID id) {
        return db.queryForObject("SELECT status FROM production_execution_segments WHERE id=?", String.class, id);
    }

    private static void qty(String expected, BigDecimal value) {
        org.assertj.core.api.Assertions.assertThat(value).isEqualByComparingTo(expected);
    }
}
