package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.subcontract.draw.SubcontractDrawCommandService;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawItemRequest;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawSubmitRequest;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptService;
import com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest;
import com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine;
import com.uten.imp.features.documents.DocumentUnapprovalService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest.ArrivalLine;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.ArrivalDecisionRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.InboundExpectationTask;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalControlService;
import com.uten.imp.features.warehouse.inbound.WarehouseArrivalRegistrationService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.stream.Stream;
import java.util.stream.StreamSupport;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Actual receipt and actual material consumption must not be replaced by a loss budget. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SubcontractActualReceiptAllowanceEndToEndTest extends SubcontractFullChainTestContext {
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SubcontractDrawCommandService draws;
    @Autowired SubcontractMaterialIssueService issues;
    @Autowired WarehouseArrivalRegistrationService arrivals;
    @Autowired SubcontractReceiptService receipts;
    @Autowired ProcurementArrivalControlService arrivalControl;
    @Autowired DocumentUnapprovalService unapproval;
    SubcontractStepDrawEndToEndTest h;

    @BeforeEach void setup() {
        h = new SubcontractStepDrawEndToEndTest();
        beans.autowireBean(h);
        h.setup();
    }
    @AfterEach void logout() { SecurityContextHolder.clearContext(); }

    @ParameterizedTest
    @MethodSource("normalReceiptCases")
    void actualReceiptWithinTheMaterialAllowanceRemainsTheActualStockAndConsumption(JsonNode vector) {
        String actual=vector.path("actualReceipt").asText();
        Case c = ready("actual-" + actual, true);
        UUID receipt = receive(c, actual, "one");
        amount(actual, "SELECT qty FROM subcontract_receipt_items WHERE receipt_id=?", receipt);
        amount(actual, "SELECT received_qty FROM subcontract_order_items WHERE id=?", c.item());
        amount(new BigDecimal(actual).multiply(new BigDecimal("50")).toPlainString(),
                "SELECT amount_original FROM subcontract_receipt_items WHERE receipt_id=?",receipt);
        amount(actual, "SELECT SUM(consumed_qty) FROM subcontract_material_issue_items WHERE order_item_id=? AND goods_id=?",
                c.item(), c.material());
        amount(new BigDecimal(actual).multiply(new BigDecimal("2")).toPlainString(),
                "SELECT SUM(consumed_qty) FROM subcontract_material_issue_items WHERE order_item_id=? AND goods_id=?",
                c.item(), c.second());
        amount(vector.path("supplierMaterialRemaining").asText(), "SELECT SUM(supplier_ending) FROM subcontract_material_issue_items WHERE order_item_id=? AND goods_id=?",
                c.item(), c.material());
        amount("0", "SELECT COUNT(*) FROM procurement_arrival_exceptions WHERE receipt_id=?", receipt);
        stockIn(c, receipt, "one");
        amount(actual, "SELECT SUM(qty) FROM stock_balances WHERE goods_id=? AND warehouse_id=?", c.product(), c.world().warehouseId());
        amount("1000", "SELECT qty FROM subcontract_order_items WHERE id=?", c.item());
        assertTrue(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?", Boolean.class, c.order()));
        assertTrue(db.queryForObject("SELECT fn_subcontract_receipt_material_complete(id) FROM subcontract_receipt_items WHERE receipt_id=?",
                Boolean.class, receipt));
        if("1050".equals(actual))assertActualValueConservation(c,receipt);
    }

    @ParameterizedTest
    @MethodSource("actualMaterialCases")
    void nativeActualSourcePrecisionSurvivesPartialWarehouseIssueConsumptionAndCost(JsonNode vector) {
        Case c=readyActualPartial(vector,"actual-grid-"+vector.path("id").asText());
        UUID receipt=receive(c,vector.path("outputQty").asText(),"actual");
        amount(vector.path("outputQty").asText(),"SELECT qty FROM subcontract_receipt_items WHERE receipt_id=?",receipt);
        amount(vector.path("consumedQty").asText(),"SELECT SUM(consumed_qty) FROM subcontract_material_issue_items WHERE order_item_id=?",c.item());
        amount(vector.path("consumedQty").asText(),"SELECT SUM(source.qty_doc) FROM subcontract_receipt_material_consumptions source JOIN subcontract_receipt_items item ON item.id=source.receipt_item_id WHERE item.receipt_id=? AND source.reversal_of IS NULL",receipt);
        amount(vector.path("remainingMaterialQty").asText(),"SELECT SUM(supplier_ending) FROM subcontract_material_issue_items WHERE order_item_id=?",c.item());
        amount(vector.path("physicalOutputQty").asText(),"SELECT fn_subcontract_physical_receipt_capacity(?)",c.item());
        amount("0","SELECT COUNT(*) FROM procurement_arrival_exceptions WHERE receipt_id=?",receipt);
        stockIn(c,receipt,"actual");
        amount(vector.path("outputQty").asText(),"SELECT SUM(qty) FROM stock_balances WHERE goods_id=? AND warehouse_id=?",c.product(),c.world().warehouseId());
        assertTrue(db.queryForObject("SELECT fn_subcontract_receipt_material_complete(id) FROM subcontract_receipt_items WHERE receipt_id=?",Boolean.class,receipt));
        assertFinal(receipt);
    }

    @Test
    void cumulativeRoundCreditHasExplicitZeroProofAndMustReverseAfterItsFundingSource() throws Exception {
        JsonNode vector=StreamSupport.stream(actualMaterialContract().spliterator(),false)
                .filter(v->"actual-cumulative-round-credit".equals(v.path("id").asText())).findFirst().orElseThrow();
        Case c=readyActualPartial(vector,"actual-round-credit");
        UUID first=receive(c,vector.path("outputQty").asText(),"first");
        acknowledgePartial(c);
        stockIn(c,first,"first");
        amount("0","SELECT SUM(supplier_ending) FROM subcontract_material_issue_items WHERE order_item_id=?",c.item());
        amount(vector.path("physicalOutputQty").asText(),"SELECT fn_subcontract_physical_receipt_capacity(?)",c.item());
        UUID last=receive(c,vector.path("subsequentOutputQty").asText(),"last");
        amount("1","SELECT COUNT(*) FROM subcontract_receipt_material_consumptions source JOIN subcontract_receipt_items item ON item.id=source.receipt_item_id WHERE item.receipt_id=? AND source.qty_doc=0 AND source.qty_base=0 AND source.round_credit_source_id IS NOT NULL AND source.reversal_of IS NULL",last);
        amount(vector.path("consumedQty").asText(),"SELECT SUM(consumed_qty) FROM subcontract_material_issue_items WHERE order_item_id=?",c.item());
        stockIn(c,last,"last");
        assertFalse(db.queryForObject("SELECT fn_subcontract_receipt_zero_increment_cost_complete(id) FROM subcontract_receipt_items WHERE receipt_id=?",Boolean.class,first));
        assertTrue(db.queryForObject("SELECT fn_subcontract_receipt_zero_increment_cost_complete(id) FROM subcontract_receipt_items WHERE receipt_id=?",Boolean.class,last));
        assertFinal(first);assertFinal(last);
        amount("0.00000000000000000000051","SELECT amount_local FROM stock_balances WHERE goods_id=? AND warehouse_id=?",c.product(),c.world().warehouseId());
        amount(vector.path("finishedTargetQty").asText(),"SELECT SUM(qty) FROM stock_balances WHERE goods_id=? AND warehouse_id=?",c.product(),c.world().warehouseId());
        amount("0","SELECT COUNT(*) FROM stock_value_events event JOIN subcontract_receipt_material_consumptions source ON source.id=event.source_item_id JOIN subcontract_receipt_items item ON item.id=source.receipt_item_id WHERE item.receipt_id=? AND event.source_doc_type IN('SUBCONTRACT_CONSUMED_MATERIAL','SUBCONTRACT_RECEIPT_MATERIAL')",last);
        String originals=db.queryForObject("SELECT jsonb_agg(to_jsonb(source) ORDER BY source.id)::text FROM subcontract_receipt_material_consumptions source JOIN subcontract_receipt_items item ON item.id=source.receipt_item_id WHERE item.order_item_id=? AND source.reversal_of IS NULL",String.class,c.item());
        ApiException blocked=org.junit.jupiter.api.Assertions.assertThrows(ApiException.class,()->receipts.reverse(first));
        assertEquals(ErrorCode.CONFLICT,blocked.getCode());
        assertTrue(blocked.getMessage().contains("零增量回厂"),"the real material-credit dependency must be the refusal reason");
        assertEquals(originals,db.queryForObject("SELECT jsonb_agg(to_jsonb(source) ORDER BY source.id)::text FROM subcontract_receipt_material_consumptions source JOIN subcontract_receipt_items item ON item.id=source.receipt_item_id WHERE item.order_item_id=? AND source.reversal_of IS NULL",String.class,c.item()));
        receipts.reverse(last);
        InventoryValueWorkTestSupport.drain(h.inventoryValueWork,db,List.of(c.product(),c.material()));
        receipts.reverse(first);
        InventoryValueWorkTestSupport.drain(h.inventoryValueWork,db,List.of(c.product(),c.material()));
        amount("0","SELECT received_qty FROM subcontract_order_items WHERE id=?",c.item());
        amount("0","SELECT SUM(consumed_qty) FROM subcontract_material_issue_items WHERE order_item_id=?",c.item());
        amount(vector.path("issuedQty").asText(),"SELECT SUM(supplier_ending) FROM subcontract_material_issue_items WHERE order_item_id=?",c.item());
        amount("2","SELECT COUNT(*) FROM subcontract_receipt_material_consumptions reversal JOIN subcontract_receipt_items item ON item.id=reversal.receipt_item_id WHERE item.order_item_id=? AND reversal.reversal_of IS NOT NULL",c.item());
        assertFalse(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?",Boolean.class,c.order()));
    }

    @Test
    void targetThenUnusedAllowanceCanReturnAsAnotherActualBatchWithoutReplayingTheFirst() {
        Case c = ready("actual-batch", false);
        UUID first = receive(c, "1000", "first");
        stockIn(c, first, "first");
        amount("100", "SELECT SUM(supplier_ending) FROM subcontract_material_issue_items WHERE order_item_id=?", c.item());
        UUID last = receive(c, "100", "last");
        assertEquals(last, receive(c, "100", "last"), "same request must retain the receipt identity");
        stockIn(c, last, "last");
        amount("1100", "SELECT received_qty FROM subcontract_order_items WHERE id=?", c.item());
        amount("1100", "SELECT SUM(consumed_qty) FROM subcontract_material_issue_items WHERE order_item_id=?", c.item());
        amount("0", "SELECT SUM(supplier_ending) FROM subcontract_material_issue_items WHERE order_item_id=?", c.item());
        amount("1100", "SELECT SUM(qty) FROM stock_balances WHERE goods_id=? AND warehouse_id=?", c.product(), c.world().warehouseId());
    }

    @Test
    void beyondTheApprovedAllowanceIsIsolatedWithoutCreatingStockOrMaterialConsumption() {
        Case c = ready("actual-over", false);
        var outcome = arrivals.register(request(c, "1100.0001", "beyond"));
        assertFalse("SUBMITTED_FOR_INSPECTION".equals(outcome.outcome()), "real excess needs its existing finance/ownership decision");
        amount("0", "SELECT received_qty FROM subcontract_order_items WHERE id=?", c.item());
        amount("0", "SELECT SUM(consumed_qty) FROM subcontract_material_issue_items WHERE order_item_id=?", c.item());
        amount("1100", "SELECT SUM(supplier_ending) FROM subcontract_material_issue_items WHERE order_item_id=?", c.item());
    }

    @Test
    void reversingOneActualBatchRestoresItsExactSlicesAndAllowsAReplacementBatch() {
        Case c = ready("actual-reverse", true);
        UUID first = receive(c, "400", "first");
        UUID middle = receive(c, "300", "middle");
        ReflectionTestUtils.invokeMethod(h,"passIqc","SUBCONTRACT",middle,c.tag()+"-middle-pass");
        receipts.reverse(middle);
        amount("400", "SELECT SUM(consumed_qty) FROM subcontract_material_issue_items WHERE order_item_id=? AND goods_id=?",
                c.item(), c.material());
        amount("800", "SELECT SUM(consumed_qty) FROM subcontract_material_issue_items WHERE order_item_id=? AND goods_id=?",
                c.item(), c.second());
        UUID replacement = receive(c, "700", "replacement");
        stockIn(c, first, "first");
        stockIn(c, replacement, "replacement");
        amount("1100", "SELECT received_qty FROM subcontract_order_items WHERE id=?", c.item());
        amount("0", "SELECT SUM(supplier_ending) FROM subcontract_material_issue_items WHERE order_item_id=?", c.item());
        assertEquals(2L, db.queryForObject("""
                SELECT COUNT(*) FROM subcontract_receipt_material_consumptions reversal
                JOIN subcontract_receipt_items item ON item.id=reversal.receipt_item_id
                WHERE item.receipt_id=? AND reversal.reversal_of IS NOT NULL
                """, Long.class, middle));
    }

    @Test
    void concurrentBatchReceiptsAndRapidReplaysConsumeEachActualBatchOnlyOnce() throws Exception {
        Case c=ready("actual-concurrent",true);
        var pool=Executors.newFixedThreadPool(2);
        try {
            var futures=List.of("left","right").stream().map(suffix->pool.submit(()->{
                h.fixture.loginAs(c.world().superAdminUserId());
                try {
                    var draft=request(c,"550",suffix);
                    var acknowledged=new WarehouseArrivalRegisterRequest(draft.idempotencyKey(),draft.orderType(),draft.billDate(),
                            draft.supplierId(),draft.warehouseId(),draft.purchaserId(),draft.receiverEmployeeId(),draft.remark(),draft.items(),null,true);
                    UUID receipt=null;
                    for(int repeat=0;repeat<4;repeat++) {
                        var result=arrivals.register(acknowledged);
                        assertEquals("SUBMITTED_FOR_INSPECTION",result.outcome());
                        if(receipt==null)receipt=result.receiptId();else assertEquals(receipt,result.receiptId());
                    }
                    return receipt;
                } finally {SecurityContextHolder.clearContext();}
            })).toList();
            UUID first=futures.get(0).get(90,TimeUnit.SECONDS),second=futures.get(1).get(90,TimeUnit.SECONDS);
            assertFalse(first.equals(second),"two real batches keep separate receipt identities");
            amount("1100","SELECT received_qty FROM subcontract_order_items WHERE id=?",c.item());
            amount("1100","SELECT SUM(consumed_qty) FROM subcontract_material_issue_items WHERE order_item_id=? AND goods_id=?",c.item(),c.material());
            amount("2200","SELECT SUM(consumed_qty) FROM subcontract_material_issue_items WHERE order_item_id=? AND goods_id=?",c.item(),c.second());
            amount("0","SELECT SUM(supplier_ending) FROM subcontract_material_issue_items WHERE order_item_id=?",c.item());
            amount("2","SELECT COUNT(*) FROM subcontract_receipt_items WHERE order_item_id=?",c.item());
            stockIn(c,first,"left");stockIn(c,second,"right");
            amount("1100","SELECT SUM(qty) FROM stock_balances WHERE goods_id=? AND warehouse_id=?",c.product(),c.world().warehouseId());
        } finally {pool.shutdownNow();}
    }

    @Test
    void theReported3382CaseCanReceiveItsActualTargetWithoutInventingThreePercentLoss() throws Exception {
        JsonNode vectors=new ObjectMapper().readTree(Files.readString(Path.of("../contracts/subcontract-actual-receipt/v1.json"))).path("vectors");
        JsonNode vector=StreamSupport.stream(vectors.spliterator(),false)
                .filter(v->"actual-target-without-using-buffer".equals(v.path("id").asText())).findFirst().orElseThrow();
        Case c=ready("actual-3382",false,vector.path("target").asText(),vector.path("lossPct").asText(),vector.path("issued").asText());
        UUID receipt=receive(c,vector.path("actualReceipt").asText(),"actual");
        amount(vector.path("baseConsumed").asText(),"SELECT SUM(consumed_qty) FROM subcontract_material_issue_items WHERE order_item_id=?",c.item());
        amount("0","SELECT SUM(supplier_ending) FROM subcontract_material_issue_items WHERE order_item_id=?",c.item());
        stockIn(c,receipt,"actual");
        amount(vector.path("actualReceipt").asText(),"SELECT SUM(qty) FROM stock_balances WHERE goods_id=? AND warehouse_id=?",c.product(),c.world().warehouseId());
        assertTrue(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?",Boolean.class,c.order()));
        amount("0","SELECT COUNT(*) FROM procurement_arrival_exceptions WHERE receipt_id=?",receipt);
    }

    @Test
    void approvedPublicExcessDoesNotBecomeAnotherOriginalFinishedTarget() throws Exception {
        Case c=ready("actual-approved-public",false,"1000","0","1000");
        var isolated=arrivals.register(request(c,"1050","public-extra"));
        assertEquals("EXCESS_QUARANTINED",isolated.outcome());
        UUID reviewer=ReflectionTestUtils.invokeMethod(h.fixture,"createApprover",c.world());
        h.fixture.loginAs(reviewer);
        var pending=arrivalControl.financeDetail(isolated.exceptionId());
        var decided=arrivalControl.financeDecide(isolated.exceptionId(),new ArrivalDecisionRequest(
                pending.version(),"APPROVE_ALL",null,"明确批准公共超量50及其委外商自带料来源，原成品目标不变"));
        assertEquals(0,new BigDecimal("50").compareTo(decided.approvedExcessQty()));
        h.fixture.loginAs(c.world().superAdminUserId());
        arrivalControl.stockInWithDecisionSession(isolated.exceptionId(),
                source->receipts.approveFromWarehouseDecision(source.receiptId()));
        amount("1000","SELECT qty FROM subcontract_order_items WHERE id=?",c.item());
        amount("1050","SELECT ordered_qty FROM inbound_expectation_items WHERE order_item_id=?",c.item());
        amount("1050","SELECT received_qty FROM subcontract_order_items WHERE id=?",c.item());
        // A completed task is hidden from the action list. Read its same row-projection kernel
        // with the persisted authorization header to verify target display independently.
        Class<?> headerType=java.util.Arrays.stream(ProcurementArrivalControlService.class.getDeclaredClasses())
                .filter(type->type.getSimpleName().equals("ExpectationHeader")).findFirst().orElseThrow();
        var constructor=headerType.getDeclaredConstructors()[0];constructor.setAccessible(true);
        UUID expectation=db.queryForObject("SELECT expectation_id FROM inbound_expectation_items WHERE order_item_id=?",UUID.class,c.item());
        Object header=constructor.newInstance(expectation,"SUBCONTRACT",c.order(),
                db.queryForObject("SELECT bill_no FROM subcontract_orders WHERE id=?",String.class,c.order()),
                c.world().supplierId(),null,c.world().warehouseId(),null,BusinessTime.today(),c.world().employeeId(),null,
                "CLOSED",new BigDecimal("1050"),new BigDecimal("1050"),BigDecimal.ZERO);
        InboundExpectationTask task=ReflectionTestUtils.invokeMethod(arrivalControl,"expectationTask",header,
                c.world().warehouseId(),null,List.of(),1,0);
        assertEquals(1,task.items().size());
        var item=task.items().getFirst();
        assertEquals(0,new BigDecimal("1000").compareTo(item.orderedQty()));
        BigDecimal stillPending=ReflectionTestUtils.invokeMethod(item,"pendingReturnQty");
        assertEquals(0,stillPending.signum(),"approved public excess cannot reopen original target demand");
    }

    @Test
    void historicalVersionOneSurvivesTheRealUnapprovalSuccessorAndCannotBeForged() {
        Case c=ready("actual-legacy-clone",false,"100","10","110");
        UUID original=receipts.createFromWarehouseArrival(receiptDraft(c,"100")).getId();
        UUID originalLine=db.queryForObject("SELECT id FROM subcontract_receipt_items WHERE receipt_id=?",UUID.class,original);
        // Historical fixture marker only, before any approval, material slice or AP exists.
        // Actual approval, reversal, successor assembly and reapproval all run with origin guards.
        new org.springframework.transaction.support.TransactionTemplate(h.transactions).executeWithoutResult(tx->{
            db.execute("SET LOCAL session_replication_role=replica");
            try {assertEquals(1,db.update("UPDATE subcontract_receipt_items SET material_consumption_version=1 WHERE id=?",originalLine));}
            finally {db.execute("SET LOCAL session_replication_role=origin");}
        });
        receipts.approve(original);
        amount("110","SELECT SUM(consumed_qty) FROM subcontract_material_issue_items WHERE order_item_id=?",c.item());
        ReflectionTestUtils.invokeMethod(h,"passIqc","SUBCONTRACT",original,c.tag()+"-old-pass");
        InventoryValueWorkTestSupport.drain(h.inventoryValueWork,db,List.of(c.product(),c.material()));
        String oldSlice=db.queryForObject("SELECT to_jsonb(source)::text FROM subcontract_receipt_material_consumptions source WHERE receipt_item_id=? AND reversal_of IS NULL",String.class,originalLine);
        FrozenUnapprovalInputs.unapprove(db,unapproval,"subcontractReceipt",original,
                new DocumentUnapprovalService.UnapproveRequest("legacy-receipt-"+UUID.randomUUID(),"核对历史估算后按原单反审生成新草稿"));
        UUID successor=db.queryForObject("SELECT draft_id FROM document_unapprovals WHERE family='subcontractReceipt' AND original_id=?",UUID.class,original);
        UUID successorLine=db.queryForObject("SELECT id FROM subcontract_receipt_items WHERE receipt_id=?",UUID.class,successor);
        assertFalse(original.equals(successor));assertFalse(originalLine.equals(successorLine));
        assertEquals(originalLine,db.queryForObject("SELECT unapproval_source_item_id FROM subcontract_receipt_items WHERE id=?",UUID.class,successorLine));
        assertEquals(1,db.queryForObject("SELECT material_consumption_version FROM subcontract_receipt_items WHERE id=?",Integer.class,successorLine));
        assertEquals(oldSlice,db.queryForObject("SELECT to_jsonb(source)::text FROM subcontract_receipt_material_consumptions source WHERE receipt_item_id=? AND reversal_of IS NULL",String.class,originalLine),"the original source slice is never rewritten");
        amount("0","SELECT SUM(consumed_qty) FROM subcontract_material_issue_items WHERE order_item_id=?",c.item());
        InventoryValueWorkTestSupport.drain(h.inventoryValueWork,db,List.of(c.product(),c.material()));
        receipts.approve(successor);
        amount("110","SELECT SUM(consumed_qty) FROM subcontract_material_issue_items WHERE order_item_id=?",c.item());
        amount("110","SELECT SUM(qty_doc) FROM subcontract_receipt_material_consumptions WHERE receipt_item_id=? AND reversal_of IS NULL",successorLine);
        assertEquals("FROZEN_BOM_ESTIMATE",db.queryForObject("SELECT consumption_basis FROM subcontract_receipt_material_consumptions WHERE receipt_item_id=? AND reversal_of IS NULL",String.class,successorLine));
        stockIn(c,successor,"new-pass");
        amount("6100","SELECT amount_local FROM stock_balances WHERE goods_id=? AND warehouse_id=?",c.product(),c.world().warehouseId());
        UUID unrelated=receipts.createFromWarehouseArrival(receiptDraft(c,"1")).getId();
        UUID unrelatedLine=db.queryForObject("SELECT id FROM subcontract_receipt_items WHERE receipt_id=?",UUID.class,unrelated);
        org.junit.jupiter.api.Assertions.assertThrows(org.springframework.dao.DataAccessException.class,
                ()->db.update("UPDATE subcontract_receipt_items SET material_consumption_version=1 WHERE id=?",unrelatedLine));
        UUID forged=UUID.randomUUID();
        var denial=org.junit.jupiter.api.Assertions.assertThrows(org.springframework.dao.DataAccessException.class,()->db.update("""
                INSERT INTO subcontract_receipt_items(id,receipt_id,bill_no,bill_date,line_no,order_item_id,
                    goods_id,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,color_id,unit_id,unit_rate,qty,price,
                    material_consumption_version,unapproval_source_item_id,created_by,updated_by)
                SELECT ?,?,bill_no,bill_date,2,order_item_id,goods_id,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,
                    color_id,unit_id,unit_rate,qty,price,1,id,created_by,updated_by FROM subcontract_receipt_items WHERE id=?
                """,forged,unrelated,originalLine));
        assertTrue(denial.getMostSpecificCause().getMessage().contains("lineage"),denial.getMostSpecificCause().getMessage());
        amount("0","SELECT COUNT(*) FROM subcontract_receipt_items WHERE id=?",forged);
        assertEquals(2,db.queryForObject("SELECT material_consumption_version FROM subcontract_receipt_items WHERE id=?",Integer.class,unrelatedLine));
    }

    private ReceiptSaveRequest receiptDraft(Case c,String actual) {
        var request=new ReceiptSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(c.world().supplierId());
        request.setWarehouseId(c.world().warehouseId());request.setCurrencyId(c.world().currencyId());
        request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(db.queryForObject("SELECT settlement_method_id FROM subcontract_orders WHERE id=?",UUID.class,c.order()));
        var line=new ReceiptItemLine();line.setGoodsId(c.product());line.setUnitId(c.world().unitId());
        line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(actual));line.setPrice(new BigDecimal("50"));line.setOrderItemId(c.item());
        request.setItems(List.of(line));return request;
    }

    private Case ready(String tag, boolean twoMaterials) {
        return ready(tag,twoMaterials,"1000","10","1100");
    }
    private Case ready(String tag,boolean twoMaterials,String target,String lossPct,String issued) {
        var w = h.fixture.seedWorld(tag);
        h.fixture.loginAs(w.superAdminUserId());
        db.update("""
                INSERT INTO user_permission_overrides(user_id,permission_id,effect)
                SELECT ?,id,'grant' FROM permissions WHERE code IN
                    ('subcontract_order:view','subcontract_order:draw','subcontract:view:all')
                """, w.superAdminUserId());
        UUID p = ReflectionTestUtils.invokeMethod(h,"goods",w,tag,"P","委外");
        UUID a = ReflectionTestUtils.invokeMethod(h,"goods",w,tag,"A","自制");
        UUID b = twoMaterials ? ReflectionTestUtils.invokeMethod(h,"goods",w,tag,"B","采购") : null;
        h.fixture.insertBom(p,a,"1");
        if (b != null) h.fixture.insertBom(p,b,"2");
        UUID order = ReflectionTestUtils.invokeMethod(h,"subcontractOrder",w,p,target,BusinessTime.today().plusDays(5),new BigDecimal(lossPct));
        ReflectionTestUtils.invokeMethod(h,"approveSubcontract",w,order);
        UUID item = ReflectionTestUtils.invokeMethod(h,"itemOf",order);
        ReflectionTestUtils.invokeMethod(h,"otherIn",w,w.warehouseId(),a,null,issued,"10");
        if (b != null) ReflectionTestUtils.invokeMethod(h,"otherIn",w,w.warehouseId(),b,null,new BigDecimal(issued).multiply(new BigDecimal("2")).toPlainString(),"5");
        UUID issue = draws.submit(new DrawSubmitRequest(List.of(new DrawItemRequest(item,null)),tag+"-draw-"+item)).issueIds().getFirst();
        issues.approve(issue);
        amount(issued, "SELECT SUM(issued_qty) FROM subcontract_material_plan_items WHERE order_item_id=? AND goods_id=?",item,a);
        return new Case(w,order,item,p,a,b,tag);
    }

    private Case readyActualPartial(JsonNode vector,String tag) {
        var w=h.fixture.seedWorld(tag);h.fixture.loginAs(w.superAdminUserId());
        db.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'grant' FROM permissions WHERE code IN('subcontract_order:view','subcontract_order:draw','subcontract:view:all')",w.superAdminUserId());
        UUID product=ReflectionTestUtils.invokeMethod(h,"goods",w,tag,"P","委外");
        UUID material=ReflectionTestUtils.invokeMethod(h,"goods",w,tag,"A","自制");
        h.fixture.insertBom(product,material,vector.path("baseBomQty").asText());
        UUID order=ReflectionTestUtils.invokeMethod(h,"subcontractOrder",w,product,vector.path("finishedTargetQty").asText(),BusinessTime.today().plusDays(5),new BigDecimal(vector.path("lossPct").asText()));
        ReflectionTestUtils.invokeMethod(h,"approveSubcontract",w,order);
        UUID item=ReflectionTestUtils.invokeMethod(h,"itemOf",order);
        ReflectionTestUtils.invokeMethod(h,"otherIn",w,w.warehouseId(),material,null,vector.path("stockBeforeIssueQty").asText(),"10");
        UUID issue=draws.submit(new DrawSubmitRequest(List.of(new DrawItemRequest(item,null)),tag+"-draw-"+item)).issueIds().getFirst();
        amount(vector.path("plannedMaterialQty").asText(),"SELECT qty FROM subcontract_material_issue_items WHERE issue_id=?",issue);
        ReflectionTestUtils.invokeMethod(h,"warehousePick",issue,material,vector.path("issuedQty").asText());
        issues.approve(issue);
        InventoryValueWorkTestSupport.drain(h.inventoryValueWork,db,List.of(product,material));
        amount(vector.path("issuedQty").asText(),"SELECT qty FROM subcontract_material_issue_items WHERE issue_id=?",issue);
        return new Case(w,order,item,product,material,null,tag);
    }
    private void acknowledgePartial(Case c) {
        var open=db.queryForList("SELECT id,version FROM subcontract_short_delivery_cases WHERE order_item_id=? AND status IN('PENDING_OWNER','WAITING_MORE') ORDER BY detected_at DESC",c.item());
        if(!open.isEmpty()) h.shortDelivery.decide((UUID)open.getFirst().get("id"),new com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.DecisionRequest(
                "WAIT_MORE",BusinessTime.today().plusDays(1),"确认分批回厂，继续等待原成品目标",((Number)open.getFirst().get("version")).longValue()));
        amount("0","SELECT fn_subcontract_settled_loss_qty(?)",c.item());
    }
    private void assertFinal(UUID receipt) {
        assertEquals("FINAL",db.queryForObject("SELECT cost.state FROM stock_value_production_cost_objects cost JOIN subcontract_receipt_items item ON item.id=cost.execution_segment_id WHERE item.receipt_id=?",String.class,receipt));
    }

    private UUID receive(Case c,String actual,String suffix) {
        var original=request(c,actual,suffix);
        Long receiptCountBefore=db.queryForObject("SELECT COUNT(*) FROM subcontract_receipt_items WHERE order_item_id=?",Long.class,c.item());
        BigDecimal consumedBefore=db.queryForObject("SELECT COALESCE(SUM(consumed_qty),0) FROM subcontract_material_issue_items WHERE order_item_id=?",BigDecimal.class,c.item());
        com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterResult result;
        try {
            result=arrivals.register(original);
        } catch (ApiException confirmation) {
            if(confirmation.getCode()!=ErrorCode.SUBCONTRACT_SHORT_DELIVERY_UNACKNOWLEDGED)throw confirmation;
            assertEquals(receiptCountBefore,db.queryForObject("SELECT COUNT(*) FROM subcontract_receipt_items WHERE order_item_id=?",Long.class,c.item()),"unacknowledged short delivery must not save a receipt");
            assertEquals(0,consumedBefore.compareTo(db.queryForObject("SELECT COALESCE(SUM(consumed_qty),0) FROM subcontract_material_issue_items WHERE order_item_id=?",BigDecimal.class,c.item())),"unacknowledged short delivery must not consume material");
            result=arrivals.register(new WarehouseArrivalRegisterRequest(original.idempotencyKey(),original.orderType(),original.billDate(),
                    original.supplierId(),original.warehouseId(),original.purchaserId(),original.receiverEmployeeId(),original.remark(),original.items(),null,true));
        }
        assertEquals("SUBMITTED_FOR_INSPECTION",result.outcome(),"actual receipt "+actual+" within the budget must not be recast as supplier-owned material");
        return result.receiptId();
    }
    private WarehouseArrivalRegisterRequest request(Case c,String actual,String suffix) {
        return new WarehouseArrivalRegisterRequest(c.tag()+"-"+suffix+"-"+c.item(),"SUBCONTRACT",BusinessTime.today(),
                c.world().supplierId(),c.world().warehouseId(),null,c.world().employeeId(),null,
                List.of(new ArrivalLine(c.product(),new BigDecimal(actual),c.item(),null,c.world().unitId(),BigDecimal.ONE,null,null)));
    }
    private void stockIn(Case c,UUID receipt,String suffix) {
        Object pass = ReflectionTestUtils.invokeMethod(h,"passIqc","SUBCONTRACT",receipt,c.tag()+"-"+suffix);
        ReflectionTestUtils.invokeMethod(h,"stockIn","SUBCONTRACT",receipt,pass,c.tag()+"-"+suffix,c.world().warehouseId());
        InventoryValueWorkTestSupport.drain(h.inventoryValueWork,db,c.second()==null
                ?List.of(c.product(),c.material()):List.of(c.product(),c.material(),c.second()));
    }
    private void assertActualValueConservation(Case c,UUID receipt) {
        InventoryValueWorkTestSupport.drain(h.inventoryValueWork,db,List.of(c.product(),c.material(),c.second()));
        amount("10","SELECT item.price FROM stock_document_items item JOIN stock_documents source ON source.id=item.doc_id WHERE item.goods_id=? AND source.warehouse_id=? AND source.doc_type='OTHER_IN' AND source.status=1",c.material(),c.world().warehouseId());
        amount("5","SELECT item.price FROM stock_document_items item JOIN stock_documents source ON source.id=item.doc_id WHERE item.goods_id=? AND source.warehouse_id=? AND source.doc_type='OTHER_IN' AND source.status=1",c.second(),c.world().warehouseId());
        amount("50","SELECT price FROM subcontract_receipt_items WHERE receipt_id=?",receipt);
        amount("22000","SELECT SUM(movement.amount_local) FROM stock_movements movement JOIN subcontract_material_issue_items issue ON issue.id=movement.source_item_id WHERE issue.order_item_id=? AND movement.source_doc_type='SUBCONTRACT_MATERIAL_ISSUE' AND movement.direction=-1",c.item());
        amount("52500","SELECT amount_local FROM subcontract_receipt_items WHERE receipt_id=?",receipt);
        amount("21000","""
                SELECT SUM(node.owned_value_local+node.distributed_value_local)
                FROM stock_value_production_cost_inputs input JOIN stock_value_nodes node ON node.id=input.input_node_id
                JOIN subcontract_receipt_items receipt ON receipt.id=input.execution_segment_id
                WHERE receipt.receipt_id=? AND input.input_kind='CONSUMED'
                """,receipt);
        amount("73500","SELECT amount_local FROM stock_balances WHERE goods_id=? AND warehouse_id=?",c.product(),c.world().warehouseId());
        amount("1000","""
                SELECT COALESCE(SUM(node.owned_value_local),0) FROM stock_value_nodes node
                JOIN subcontract_material_issue_items issue ON issue.id=node.owner_id
                WHERE node.owner_kind='SUBCONTRACT_WIP' AND issue.order_item_id=?
                """,c.item());
        amount("74500","""
                SELECT (SELECT amount_local FROM stock_balances WHERE goods_id=? AND warehouse_id=?)
                  +(SELECT COALESCE(SUM(node.owned_value_local),0) FROM stock_value_nodes node
                    JOIN subcontract_material_issue_items issue ON issue.id=node.owner_id
                    WHERE node.owner_kind='SUBCONTRACT_WIP' AND issue.order_item_id=?)
                """,c.product(),c.world().warehouseId(),c.item());
        assertEquals("FINAL",db.queryForObject("""
                SELECT cost.state FROM stock_value_production_cost_objects cost
                JOIN subcontract_receipt_items item ON item.id=cost.execution_segment_id WHERE item.receipt_id=?
                """,String.class,receipt));
    }
    private void amount(String expected,String sql,Object...args) {
        BigDecimal actual=db.queryForObject(sql,BigDecimal.class,args);
        org.junit.jupiter.api.Assertions.assertNotNull(actual,sql+" must return a known authoritative quantity or value");
        assertEquals(0,new BigDecimal(expected).compareTo(actual),sql+" expected "+expected+" actual "+actual);
    }
    private static Stream<JsonNode> normalReceiptCases() throws Exception {
        JsonNode vectors=new ObjectMapper().readTree(Files.readString(Path.of("../contracts/subcontract-actual-receipt/v1.json"))).path("vectors");
        return StreamSupport.stream(vectors.spliterator(),false)
                .filter(v->List.of("minimum","variable-loss","no-loss").contains(v.path("id").asText()));
    }
    private static JsonNode actualMaterialContract() throws Exception {
        return new ObjectMapper().readTree(Files.readString(Path.of("../contracts/subcontract-actual-receipt/v1.json"))).path("actualMaterialVectors");
    }
    private static Stream<JsonNode> actualMaterialCases() throws Exception {
        return StreamSupport.stream(actualMaterialContract().spliterator(),false)
                .filter(v->!"actual-cumulative-round-credit".equals(v.path("id").asText()));
    }
    private record Case(FullChainEndToEndTest.World world,UUID order,UUID item,UUID product,UUID material,UUID second,String tag) {}
}
