package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.documents.DocumentUnapprovalService;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.purchase.ret.PurchaseReturnService;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService;
import com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest;
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
import static com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.*;
import static org.assertj.core.api.Assertions.*;

/** One isolated migrated context; new business data and actual approval/quality/stock/value ports in every case. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.inventory.value-work.enabled=false",
    "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
    "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=false",
    "uten.jwt.secret=gift-regression-isolated-jwt-key-0123456789-abcdef", // gitleaks:allow synthetic test-only cryptographic fixture.
    "uten.crypto.pgp-master-key=gift-regression-isolated-pgp-key-0123456789-abcdef", // gitleaks:allow synthetic test-only cryptographic fixture.
    "uten.crypto.hmac-key=gift-regression-isolated-hmac-key-0123456789-abcdef",
    "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class ProcurementUnapprovalEligibilityEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PurchaseRequestService requests;
    @Autowired PurchaseOrderService orders;
    @Autowired PurchaseReceiptService receipts;
    @Autowired PurchaseReturnService returns;
    @Autowired com.uten.imp.features.subcontract.order.SubcontractOrderService subcontractOrders;
    @Autowired com.uten.imp.features.subcontract.receipt.SubcontractReceiptService subcontractReceipts;
    @Autowired com.uten.imp.features.subcontract.ret.SubcontractReturnService subcontractReturns;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired TaskClaimService claims;
    @Autowired ProcurementInspectionService inspection;
    @Autowired ProcurementIqcStockInService stockIn;
    @Autowired DocumentUnapprovalService unapproval;
    @Autowired com.uten.imp.features.finance.gl.GlPostingService gl;
    @Autowired com.uten.imp.features.finance.gl.SystemPostingStyleService styles;
    private FullChainEndToEndTest harness;
    private record F(FullChainEndToEndTest.World w,UUID requestItem,UUID order,UUID orderItem,UUID currency){}
    @BeforeEach void prepare(){harness=new FullChainEndToEndTest();beans.autowireBean(harness);}
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test @Order(1) void pendingIqcBlocksWithoutWritesThenExactChargedAndGiftSourcesCanUnapprove(){
        F f=fixture();UUID id=receipt(f,"10","1");receipts.approve(id);
        blockedWithoutWrites(()->receipts.unapprovalEligibility(id),"质检");
        assertThatThrownBy(()->unapprove("purchaseReceipt",id)).isInstanceOf(com.uten.imp.common.web.ApiException.class);
        passAndStock(f,id);allowedWithoutWrites(()->receipts.unapprovalEligibility(id));
        var result=unapprove("purchaseReceipt",id);assertThat(result).isNotEqualTo(id);
        assertThat(stock(f)).isZero();assertThat(value(f)).isZero();assertThat(ap(id)).isZero();
        var draft=receipts.detail(result);assertThat(draft.getStatus()).isZero();assertThat(draft.getItems().getFirst().getQty()).isEqualByComparingTo("10");assertThat(draft.getItems().getFirst().getGiftQty()).isEqualByComparingTo("1");
        assertThat(number("SELECT received_qty+gift_received_qty FROM purchase_order_items WHERE id=?",f.orderItem())).isZero();
    }
    @Test @Order(2) void freeReturnReadyButReceiptWithRealIssueHistoryStaysBlockedEvenAfterReturnUnapproval(){
        F f=fixture();UUID id=receipt(f,"10","1");receipts.approve(id);passAndStock(f,id);
        UUID returned=returned(f,receipts.detail(id).getItems().getFirst().getId(),"0","1");returns.approve(returned);
        assertThat(ap(returned)).isZero();blockedWithoutWrites(()->receipts.unapprovalEligibility(id),"退货");
        allowedWithoutWrites(()->returns.unapprovalEligibility(returned));unapprove("purchaseReturn",returned);
        assertThat(stock(f)).isEqualByComparingTo("11");assertThat(value(f)).isEqualByComparingTo("100");assertThat(ap(id)).isEqualByComparingTo("100");
        blockedWithoutWrites(()->receipts.unapprovalEligibility(id),"出库");var before=facts();
        assertThatThrownBy(()->unapprove("purchaseReceipt",id)).isInstanceOf(com.uten.imp.common.web.ApiException.class);assertThat(facts()).isEqualTo(before);
    }
    @Test @Order(3) void previousPeriodReturnProjectionBlocksBeforeEitherInventoryOrLedgerChanges(){
        F f;UUID returned;var oldDate=BusinessTime.today().minusMonths(1);
        try(var clock=org.mockito.Mockito.mockStatic(BusinessTime.class,org.mockito.Mockito.CALLS_REAL_METHODS)){
            clock.when(BusinessTime::today).thenReturn(oldDate);
            f=fixture();UUID id=receipt(f,"10","1");receipts.approve(id);passAndStock(f,id);
            returned=returned(f,receipts.detail(id).getItems().getFirst().getId(),"1","0");returns.approve(returned);
        }
        blockedWithoutWrites(()->returns.unapprovalEligibility(returned),"会计期间");String before=facts();
        assertThatThrownBy(()->unapprove("purchaseReturn",returned)).isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("会计期间");assertThat(facts()).isEqualTo(before);
    }
    @Test @Order(4) void subcontractPassedButUnstoredReceiptCanRestoreTheExactOriginalMaterialCustody(){
        SC f=subcontractFixture(false);allowedWithoutWrites(()->subcontractReceipts.unapprovalEligibility(f.receipt()));unapprove("subcontractReceipt",f.receipt());
        assertThat(ap(f.receipt())).isZero();assertThat(number("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",f.w().goodsE())).isZero();
        assertThat(number("SELECT SUM(issue.consumed_qty) FROM subcontract_material_issue_items issue JOIN subcontract_material_issues doc ON doc.id=issue.issue_id WHERE issue.order_item_id=?",f.orderItem())).isZero();
    }
    @Test @Order(5) void subcontractStoredMaterialAndFeeCanUnapproveThroughTheProvenCostReleasePlan(){
        SC f=subcontractFixture(true);assertThat(number("SELECT amount_local FROM stock_balances WHERE warehouse_id=? AND goods_id=?",f.w().warehouseId(),f.w().goodsE())).isEqualByComparingTo("600");
        allowedWithoutWrites(()->subcontractReceipts.unapprovalEligibility(f.receipt()));unapprove("subcontractReceipt",f.receipt());
        assertThat(ap(f.receipt())).isZero();assertThat(number("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",f.w().goodsE())).isZero();
        assertThat(number("SELECT COALESCE(SUM(amount_local),0) FROM stock_balances WHERE goods_id=?",f.w().goodsE())).isZero();
    }
    @Test @Order(6) void subcontractReturnUsesOriginalActualIssueAndRemainsReversibleWithoutTouchingFeeCredit(){
        SC f=subcontractFixture(true);UUID id=subcontractReturned(f);subcontractReturns.approve(id);
        assertThat(ap(id)).isEqualByComparingTo("-50");assertThat(number("SELECT amount_local FROM stock_balances WHERE warehouse_id=? AND goods_id=?",f.w().warehouseId(),f.w().goodsE())).isEqualByComparingTo("540");
        blockedWithoutWrites(()->subcontractReceipts.unapprovalEligibility(f.receipt()),"退货");allowedWithoutWrites(()->subcontractReturns.unapprovalEligibility(id));unapprove("subcontractReturn",id);
        assertThat(ap(id)).isZero();assertThat(number("SELECT amount_local FROM stock_balances WHERE warehouse_id=? AND goods_id=?",f.w().warehouseId(),f.w().goodsE())).isEqualByComparingTo("600");
        blockedWithoutWrites(()->subcontractReceipts.unapprovalEligibility(f.receipt()),"出库");
    }
    @Test @Order(7) void viewOnlyAndHiddenOwnerCannotLearnOrExecuteOtherPersonsUnapproval(){
        F f=fixture();UUID id=receipt(f,"10","1");receipts.approve(id);passAndStock(f,id);
        UUID viewer=harness.createUserWithPerms(f.w(),"receipt-view-"+id,"purchase_receipt:view","purchase:view:all");harness.loginAs(viewer);String before=facts();
        var cap=receipts.unapprovalEligibility(id);assertThat(cap.eligible()).isFalse();assertThat(cap.reasons()).extracting(com.uten.imp.application.port.DocumentUnapprovalPort.Reason::code).contains("MISSING_REVERSE_PERMISSION");assertThat(cap.relatedDocuments()).isEmpty();assertThat(facts()).isEqualTo(before);
        UUID hidden=harness.createUserWithPerms(f.w(),"receipt-hidden-"+id,"purchase_receipt:view","purchase_receipt:reverse");harness.loginAs(hidden);
        assertThatThrownBy(()->receipts.unapprovalEligibility(id)).isInstanceOf(com.uten.imp.common.web.ApiException.class);assertThatThrownBy(()->unapprove("purchaseReceipt",id)).isInstanceOf(com.uten.imp.common.web.ApiException.class);assertThat(facts()).isEqualTo(before);
    }
    @Test @Order(8) void multipleSubcontractWarehouseBatchesUseOneProvenCostReleaseAndAllOriginalStoreSlices(){
        SC f=subcontractFixture(false);
        for(int i=0;i<2;i++){
            UUID keeper=ReflectionTestUtils.invokeMethod(harness,"createIqcWarehouseConfirmer",f.w(),"sc-two-keeper-"+f.receipt()+i);harness.loginAs(keeper);
            var command=ReflectionTestUtils.<com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest>invokeMethod(harness,"latestIqcStockInRequest","SUBCONTRACT",f.receipt(),f.inspectionId(),new BigDecimal("5"),"sc-two-stock-"+f.receipt()+i,"SC-TWO-BIN");
            stockIn.confirm("SUBCONTRACT",f.receipt(),command);harness.loginAs(f.w().superAdminUserId());ReflectionTestUtils.invokeMethod(harness,"drainCosts",f.w());
        }
        assertThat(number("SELECT amount_local FROM stock_balances WHERE warehouse_id=? AND goods_id=?",f.w().warehouseId(),f.w().goodsE())).isEqualByComparingTo("600");
        allowedWithoutWrites(()->subcontractReceipts.unapprovalEligibility(f.receipt()));unapprove("subcontractReceipt",f.receipt());
        assertThat(number("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",f.w().goodsE())).isZero();assertThat(ap(f.receipt())).isZero();
    }
    @Test @Order(9) void confirmedAllFreeReceiptKeepsZeroMoneyProofWhileExactPhysicalQuantityUnapproves(){
        F f=freeFixture();UUID id=receipt(f,"0","1");receipts.approve(id);passAndStock(f,id);
        assertThat(stock(f)).isEqualByComparingTo("1");assertThat(value(f)).isZero();assertThat(ap(id)).isZero();
        allowedWithoutWrites(()->receipts.unapprovalEligibility(id));unapprove("purchaseReceipt",id);
        assertThat(stock(f)).isZero();assertThat(value(f)).isZero();assertThat(ap(id)).isZero();
        assertThat(number("SELECT COUNT(*) FROM stock_value_postings post JOIN stock_value_events event ON event.id=post.event_id WHERE event.source_doc_id=?",id)).isZero();
    }

    @Test @Order(10) void unstartedReadyProductionKitCanDemoteThroughTheSamePureUnwindPlan(){
        var w=harness.seedWorld("cap-ready-"+UUID.randomUUID());harness.loginAs(w.superAdminUserId());
        UUID root=UUID.randomUUID(),material=UUID.randomUUID();harness.insertGoods(root,"CAPR-"+root,"反审就绪产品","自制",w.unitId(),w.unitLegacy());harness.insertGoods(material,"CAPM-"+material,"反审就绪原料","采购",w.unitId(),w.unitLegacy());harness.insertBom(root,material,"2");
        UUID orderItem=ReflectionTestUtils.invokeMethod(harness,"procureDirectBuy",w,root,material,"10");
        harness.loginAs(w.superAdminUserId()); // The procurement helper legitimately ends as its separate finance approver.
        var request=new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(w.supplierId());request.setWarehouseId(w.warehouseId());
        var line=new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();line.setGoodsId(material);line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal("20"));line.setOrderItemId(orderItem);request.setItems(List.of(line));
        UUID id=receipts.create(request).getId();receipts.approve(id);
        UUID iqc=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='PURCHASE' AND receipt_id=?",UUID.class,id);
        inspection.dispose("PURCHASE",id,iqc,new InspectionDispositionRequest("PASS",null,"真实当前期间原料验收","cap-ready-pass-"+iqc));
        UUID keeper=ReflectionTestUtils.invokeMethod(harness,"createIqcWarehouseConfirmer",w,"cap-ready-keeper-"+id);harness.loginAs(keeper);
        var command=ReflectionTestUtils.<com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest>invokeMethod(harness,"latestIqcStockInRequest","PURCHASE",id,iqc,new BigDecimal("20"),"cap-ready-stock-"+iqc,"CAP-READY-BIN");
        stockIn.confirm("PURCHASE",id,command);harness.loginAs(w.superAdminUserId());ReflectionTestUtils.invokeMethod(harness,"drainCosts",w);
        UUID segment=db.queryForObject("SELECT DISTINCT demand.execution_segment_id FROM production_material_receipt_allocations allocation JOIN production_material_demands demand ON demand.id=allocation.demand_id WHERE allocation.receipt_id=? AND allocation.status='EFFECTIVE'",UUID.class,id);
        assertThat(db.queryForObject("SELECT status FROM production_execution_segments WHERE id=?",String.class,segment)).isEqualTo("READY");
        allowedWithoutWrites(()->receipts.unapprovalEligibility(id));unapprove("purchaseReceipt",id);
        assertThat(db.queryForObject("SELECT status FROM production_execution_segments WHERE id=?",String.class,segment)).isEqualTo("WAITING");
        assertThat(number("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",material)).isZero();assertThat(ap(id)).isZero();
        assertThat(number("SELECT COUNT(*) FROM production_material_receipt_allocations WHERE receipt_id=? AND status='EFFECTIVE'",id)).isZero();
    }

    @Test @Order(11) void forwardMigrationRetainsAllOriginalCustodyAndZeroMoneyDispatchGuards(){
        String source=db.queryForObject("SELECT pg_get_functiondef('fn_check_stock_value_reverse_store()'::regprocedure)",String.class);
        assertThat(source).contains("NOT fn_stock_value_stored_cost_reversible(original.result_node_id)","fn_assert_workshop_material_value_store_reverse(NEW.id)","fn_assert_unused_stock_receipt_reversal(NEW.id)","NEW.known_value_local=0","parts=0 OR parts>100","qty<>NEW.qty_base","transfer.initial_value_local=0");
        assertThat(source).doesNotContain("EXISTS(SELECT 1 FROM stock_value_production_cost_outputs WHERE source_node_id=original.result_node_id)");
    }

    private UUID unapprove(String family,UUID id){
        unapproval.unapprove(family,id,new DocumentUnapprovalService.UnapproveRequest("procurement-cap-"+UUID.randomUUID(),"真实反审核对"));
        return db.queryForObject("SELECT draft_id FROM document_unapprovals WHERE family=? AND original_id=?",UUID.class,family,id);
    }
    private void allowedWithoutWrites(java.util.function.Supplier<com.uten.imp.application.port.DocumentUnapprovalPort.Eligibility> read){
        String before=facts();var result=read.get();assertThat(result.eligible()).withFailMessage("%s",result.reasons()).isTrue();assertThat(result.factsSnapshot()).matches("[a-f0-9]{64}");assertThat(result.relatedDocuments()).isEmpty();assertThat(facts()).isEqualTo(before);
    }
    private void blockedWithoutWrites(java.util.function.Supplier<com.uten.imp.application.port.DocumentUnapprovalPort.Eligibility> read,String message){
        String before=facts();var result=read.get();assertThat(result.eligible()).isFalse();assertThat(result.reasons()).extracting(com.uten.imp.application.port.DocumentUnapprovalPort.Reason::message).anyMatch(text->text.contains(message));assertThat(result.relatedDocuments()).isEmpty();assertThat(facts()).isEqualTo(before);
    }
    private String facts(){
        String[] tables={"stock_balances","stock_movements","stock_value_pools","stock_value_nodes","stock_value_events","stock_value_postings","ar_ap_ledger","gl_vouchers","gl_entries","purchase_receipts","purchase_receipt_items","purchase_returns","purchase_return_items","purchase_order_items","subcontract_receipts","subcontract_receipt_items","subcontract_returns","subcontract_return_items","subcontract_order_items","subcontract_material_issue_items","subcontract_receipt_material_consumptions","procurement_inspection_items","procurement_iqc_rejection_cases","procurement_receipt_consideration_parts","procurement_iqc_consideration_reversals","document_unapprovals","stock_value_production_cost_objects","stock_value_production_cost_shares","stock_value_production_cost_tasks"};
        var facts=new ArrayList<String>();for(String table:tables){ facts.add(db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(row) ORDER BY to_jsonb(row)::text),'[]'::jsonb)::text FROM "+table+" row",String.class)); }return String.join("\n",facts);
    }

    private record SC(FullChainEndToEndTest.World w,UUID orderItem,UUID receipt,UUID inspectionId){}
    private SC subcontractFixture(boolean store){
        var w=harness.seedWorld("sc-return-gl-"+UUID.randomUUID());harness.loginAs(w.superAdminUserId());
        UUID material=harness.ensureSubcontractDirectMaterial(w,w.goodsE());harness.receiveSubcontractMaterial(w,material,"20");
        harness.seedChartOfAccounts();configureVarianceRole();
        UUID currency=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class);
        var order=new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
        order.setBillDate(BusinessTime.today());order.setSupplierId(w.supplierId());order.setWarehouseId(w.warehouseId());
        order.setCurrencyId(currency);order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);order.setSettlementMethodId(settlement());
        var orderLine=new com.uten.imp.features.subcontract.order.dto.OrderItemLine();
        orderLine.setGoodsId(w.goodsE());orderLine.setUnitId(w.unitId());orderLine.setUnitRate(BigDecimal.ONE);
        orderLine.setQty(BigDecimal.TEN);orderLine.setPrice(new BigDecimal("50"));order.setItems(List.of(orderLine));
        UUID orderId=subcontractOrders.create(order).getId();
        UUID reviewer=harness.createUserWithPerms(w,"sc-return-reviewer-"+orderId,"finance_order_approval:view","finance_order_approval:approve");
        harness.loginAs(w.superAdminUserId());finance.submit("SUBCONTRACT",orderId);harness.loginAs(reviewer);
        var approval=db.queryForMap("SELECT id,version FROM procurement_order_approval_cases WHERE order_type='SUBCONTRACT' AND order_id=? AND status='PENDING'",orderId);
        UUID caseId=(UUID)approval.get("id"),claim=claims.claim("PROCUREMENT_FINANCE_APPROVE",caseId.toString()).claimId();
        finance.approveBatch(List.of(new BatchDecisionItem(caseId,((Number)approval.get("version")).longValue(),claim)),null,BigDecimal.ONE);
        harness.loginAs(w.superAdminUserId());
        UUID orderItem=db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?",UUID.class,orderId);
        harness.drawAndIssueSubcontract(orderItem,BigDecimal.TEN,"sc-return-draw-"+orderItem);
        var receipt=new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();
        receipt.setBillDate(BusinessTime.today());receipt.setSupplierId(w.supplierId());receipt.setWarehouseId(w.warehouseId());
        var receiptLine=new com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine();
        receiptLine.setGoodsId(w.goodsE());receiptLine.setUnitId(w.unitId());receiptLine.setUnitRate(BigDecimal.ONE);
        receiptLine.setQty(BigDecimal.TEN);receiptLine.setOrderItemId(orderItem);receipt.setItems(List.of(receiptLine));
        UUID receiptId=subcontractReceipts.create(receipt).getId();subcontractReceipts.approve(receiptId);
        UUID inspectionId=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='SUBCONTRACT' AND receipt_id=?",UUID.class,receiptId);
        inspection.dispose("SUBCONTRACT",receiptId,inspectionId,new InspectionDispositionRequest("PASS",null,"委外材料与加工费实际入仓","sc-return-pass-"+inspectionId));
        if(store){
        UUID keeper=ReflectionTestUtils.invokeMethod(harness,"createIqcWarehouseConfirmer",w,"sc-return-keeper-"+receiptId);harness.loginAs(keeper);
        var command=ReflectionTestUtils.<com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest>invokeMethod(harness,"latestIqcStockInRequest","SUBCONTRACT",receiptId,inspectionId,BigDecimal.TEN,"sc-return-stock-"+inspectionId,"SC-RETURN-BIN");
        stockIn.confirm("SUBCONTRACT",receiptId,command);harness.loginAs(w.superAdminUserId());ReflectionTestUtils.invokeMethod(harness,"drainCosts",w);
        }
        return new SC(w,orderItem,receiptId,inspectionId);
    }
    private UUID subcontractReturned(SC f){
        var request=new com.uten.imp.features.subcontract.ret.dto.ReturnSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(f.w().supplierId());request.setWarehouseId(f.w().warehouseId());
        var line=new com.uten.imp.features.subcontract.ret.dto.ReturnItemLine();line.setGoodsId(f.w().goodsE());line.setUnitId(f.w().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(BigDecimal.ONE);line.setOrderItemId(f.orderItem());line.setReceiptItemId(subcontractReceipts.detail(f.receipt()).getItems().getFirst().getId());request.setItems(List.of(line));
        return subcontractReturns.create(request).getId();
    }
    private void configureVarianceRole(){
        var role=styles.list().stream().filter(row->row.roleKey().equals("PROCUREMENT_RETURN_VARIANCE")).findFirst().orElseThrow();
        if(!role.usable()){
            UUID style=UUID.randomUUID();db.update("INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,?,?,'EXPENSE',0,'使用')",style,"RVAR-"+style,"测试采购退货价差损益");
            styles.configure(role.roleKey(),new com.uten.imp.features.finance.gl.SystemPostingStyleService.Configure(style,role.updatedAt()));
        }
    }

    private F freeFixture(){
        var w=harness.seedWorld("gift-"+UUID.randomUUID());harness.loginAs(w.superAdminUserId());
        UUID currency=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class);
        var req=new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();req.setBillDate(BusinessTime.today());req.setWarehouseId(w.warehouseId());
        var rl=new com.uten.imp.features.purchase.request.dto.RequestItemLine();rl.setGoodsId(w.goodsD());rl.setUnitId(w.unitId());rl.setUnitRate(BigDecimal.ONE);rl.setQty(new BigDecimal("10"));rl.setGiftQty(BigDecimal.ONE);req.setItems(List.of(rl));
        var source=requests.create(req);requests.approve(source.getId());UUID requestItem=source.getItems().getFirst().getId();
        UUID reviewer=harness.createUserWithPerms(w,"gift-finance-"+UUID.randomUUID(),"finance_order_approval:view","finance_order_approval:approve");harness.loginAs(w.superAdminUserId());
        var order=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();order.setBillDate(BusinessTime.today());order.setSupplierId(w.supplierId());order.setWarehouseId(w.warehouseId());order.setCurrencyId(currency);order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);order.setSettlementMethodId(settlement());
        var line=new com.uten.imp.features.purchase.order.dto.OrderItemLine();line.setGoodsId(w.goodsD());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(BigDecimal.ZERO);line.setGiftQty(BigDecimal.ONE);line.setPrice(BigDecimal.ZERO);line.setRequestItemId(requestItem);order.setItems(List.of(line));
        UUID id=orders.create(order).getId();finance.submit("PURCHASE",id);harness.loginAs(reviewer);
        var approval=db.queryForMap("SELECT id,version FROM procurement_order_approval_cases WHERE order_type='PURCHASE' AND order_id=? AND status='PENDING'",id);UUID caseId=(UUID)approval.get("id");
        UUID claim=claims.claim("PROCUREMENT_FINANCE_APPROVE",caseId.toString()).claimId();finance.approveBatch(List.of(new BatchDecisionItem(caseId,((Number)approval.get("version")).longValue(),claim)),null,BigDecimal.ONE);harness.loginAs(w.superAdminUserId());
        return new F(w,requestItem,id,db.queryForObject("SELECT id FROM purchase_order_items WHERE order_id=?",UUID.class,id),currency);
    }

    private F fixture(){return fixture(false);}
    private F fixture(boolean foreign){
        var w=harness.seedWorld("gift-"+UUID.randomUUID());harness.loginAs(w.superAdminUserId());
        UUID currency=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class);
        if(foreign){currency=w.currencyId();assertThat(db.queryForObject("SELECT is_base_currency FROM currencies WHERE id=?",Boolean.class,currency)).isFalse();}
        var req=new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();req.setBillDate(BusinessTime.today());req.setWarehouseId(w.warehouseId());
        var rl=new com.uten.imp.features.purchase.request.dto.RequestItemLine();rl.setGoodsId(w.goodsD());rl.setUnitId(w.unitId());rl.setUnitRate(BigDecimal.ONE);rl.setQty(new BigDecimal("10"));rl.setGiftQty(BigDecimal.ONE);req.setItems(List.of(rl));
        var source=requests.create(req);requests.approve(source.getId());UUID requestItem=source.getItems().getFirst().getId();
        UUID reviewer=harness.createUserWithPerms(w,"gift-finance-"+UUID.randomUUID(),"finance_order_approval:view","finance_order_approval:approve");harness.loginAs(w.superAdminUserId());
        var order=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();order.setBillDate(BusinessTime.today());order.setSupplierId(w.supplierId());order.setWarehouseId(w.warehouseId());order.setCurrencyId(currency);order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);order.setSettlementMethodId(settlement());
        var line=new com.uten.imp.features.purchase.order.dto.OrderItemLine();line.setGoodsId(w.goodsD());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal("10"));line.setGiftQty(BigDecimal.ONE);line.setPrice(new BigDecimal("10"));line.setRequestItemId(requestItem);order.setItems(List.of(line));
        UUID id=orders.create(order).getId();finance.submit("PURCHASE",id);harness.loginAs(reviewer);
        var approval=db.queryForMap("SELECT id,version FROM procurement_order_approval_cases WHERE order_type='PURCHASE' AND order_id=? AND status='PENDING'",id);UUID caseId=(UUID)approval.get("id");
        UUID claim=claims.claim("PROCUREMENT_FINANCE_APPROVE",caseId.toString()).claimId();finance.approveBatch(List.of(new BatchDecisionItem(caseId,((Number)approval.get("version")).longValue(),claim)),null,foreign?new BigDecimal("6.234567"):BigDecimal.ONE);harness.loginAs(w.superAdminUserId());
        return new F(w,requestItem,id,db.queryForObject("SELECT id FROM purchase_order_items WHERE order_id=?",UUID.class,id),currency);
    }
    private UUID receipt(F f,String charged,String gift){
        var request=new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(f.w().supplierId());request.setWarehouseId(f.w().warehouseId());
        var line=new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();line.setGoodsId(f.w().goodsD());line.setUnitId(f.w().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(charged));line.setGiftQty(new BigDecimal(gift));line.setOrderItemId(f.orderItem());request.setItems(List.of(line));
        return receipts.create(request).getId();
    }
    private UUID returned(F f,UUID source,String charged,String gift){
        var request=new com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(f.w().supplierId());request.setWarehouseId(f.w().warehouseId());
        var line=new com.uten.imp.features.purchase.ret.dto.ReturnItemLine();line.setGoodsId(f.w().goodsD());line.setUnitId(f.w().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(charged));line.setGiftQty(new BigDecimal(gift));line.setReceiptItemId(source);line.setOrderItemId(f.orderItem());request.setItems(List.of(line));
        return returns.create(request).getId();
    }
    private void passAndStock(F f,UUID receipt){
        harness.loginAs(f.w().superAdminUserId());List<UUID> ids=db.queryForList("SELECT id FROM procurement_inspection_items WHERE receipt_id=? ORDER BY quantity_tranche",UUID.class,receipt);
        for(UUID id:ids)inspection.dispose("PURCHASE",receipt,id,new InspectionDispositionRequest("PASS",null,"真实收费/赠品质检","gift-pass-"+id));
        UUID keeper=ReflectionTestUtils.invokeMethod(harness,"createIqcWarehouseConfirmer",f.w(),"gift-keeper-"+receipt);harness.loginAs(keeper);
        for(UUID id:ids){BigDecimal qty=number("SELECT received_base_qty FROM procurement_inspection_items WHERE id=?",id);
            var command=ReflectionTestUtils.<com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest>invokeMethod(harness,"latestIqcStockInRequest","PURCHASE",receipt,id,qty,"gift-stock-"+id,"GIFT-BIN");
            var result=stockIn.confirm("PURCHASE",receipt,command);assertThat(stockIn.confirm("PURCHASE",receipt,command).batchId()).isEqualTo(result.batchId());
        }
        harness.loginAs(f.w().superAdminUserId());ReflectionTestUtils.invokeMethod(harness,"drainCosts",f.w());
    }
    private UUID settlement(){return db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class);}
    private BigDecimal number(String sql,Object...args){return db.queryForObject(sql,BigDecimal.class,args);}
    private BigDecimal stock(F f){return number("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",f.w().goodsD());}
    private BigDecimal value(F f){return number("SELECT COALESCE(SUM(amount_local),0) FROM stock_balances WHERE goods_id=?",f.w().goodsD());}
    private BigDecimal ap(UUID receipt){return number("SELECT COALESCE(SUM(amount_original_local),0) FROM ar_ap_ledger WHERE source_doc_id=? AND status=1 AND direction='AP'",receipt);}
}
