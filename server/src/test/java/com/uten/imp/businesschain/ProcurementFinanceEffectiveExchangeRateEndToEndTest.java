package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.documents.DocumentUnapprovalService;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptService;
import com.uten.imp.features.warehouse.inbound.WarehouseArrivalRegistrationService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import static com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.*;
import static com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.*;
import static org.assertj.core.api.Assertions.*;

/** Migrated real DB tests for the three independently reproduced HTTP financial defects. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=false",
        "uten.jwt.secret=fx-regression-isolated-jwt-key-0123456789-abcdef", // gitleaks:allow synthetic cryptographic key for this isolated JUnit SpringBootTest.
        "uten.crypto.pgp-master-key=fx-regression-isolated-pgp-key-0123456789-abcdef", // gitleaks:allow synthetic cryptographic key for this isolated JUnit SpringBootTest.
        "uten.crypto.hmac-key=fx-regression-isolated-hmac-key-0123456789-abcdef",
        "uten.bootstrap.admin-login=fx-regression-bootstrap","uten.bootstrap.admin-password=FxRegressionAdmin-1!"})
class ProcurementFinanceEffectiveExchangeRateEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){ FullChainEndToEndTest.registerDataSource(registry); }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PurchaseRequestService requests;
    @Autowired PurchaseOrderService purchaseOrders;
    @Autowired SubcontractOrderService subcontractOrders;
    @Autowired PurchaseReceiptService purchaseReceipts;
    @Autowired SubcontractReceiptService subcontractReceipts;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired TaskClaimService claims;
    @Autowired WarehouseArrivalRegistrationService arrivals;
    @Autowired DocumentUnapprovalService unapproval;
    @Autowired com.uten.imp.features.warehouse.inbound.ProcurementInspectionService inspections;
    @Autowired com.uten.imp.features.purchase.ret.PurchaseReturnService returns;
    private FullChainEndToEndTest harness;
    private static final BigDecimal RATE=new BigDecimal("7.123457");
    private static final BigDecimal ORIGINAL=new BigDecimal("41.010803125");
    private static final BigDecimal LOCAL=new BigDecimal("292.138692596403125");
    @BeforeEach void prepare(){ harness=new FullChainEndToEndTest(); beans.autowireBean(harness); }
    @AfterEach void clear(){ SecurityContextHolder.clearContext(); }

    @ParameterizedTest @ValueSource(strings={"PURCHASE","SUBCONTRACT"})
    void baseCurrencyRejectsNonIdentityFinancialRateBeforeAnyOrderEffect(String kind){
        Fixture f=fixture(kind,"3.125",true);
        BatchDecisionItem decision=submit(f);
        assertThatThrownBy(()->finance.approveBatch(List.of(decision),null,RATE)).isInstanceOf(ApiException.class);
        assertThat(db.queryForObject("SELECT status FROM procurement_order_approval_cases WHERE id=?",String.class,decision.caseId())).isEqualTo("PENDING");
        assertThat(db.queryForObject("SELECT finance_total_local FROM procurement_order_approval_cases WHERE id=?",BigDecimal.class,decision.caseId())).isNull();
        assertThat(decimal("SELECT status FROM "+f.prefix()+"_orders WHERE id=?",f.order())).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_id=?",Long.class,f.order())).isZero();
        assertThat(decimal("SELECT ordered_qty FROM purchase_request_items WHERE id=?",f.purchaseSource())).isZero();
    }

    @ParameterizedTest @ValueSource(strings={"PURCHASE","SUBCONTRACT"})
    void exactForeignDecisionAndDirectReceiptShareOneCaseAndReverseApWithoutLosingDigits(String kind){
        Fixture f=fixture(kind,"3.125",false); UUID caseId=approve(f,RATE);
        assertThat(decimal("SELECT finance_total_local FROM procurement_order_approval_cases WHERE id=?",caseId)).isEqualByComparingTo(LOCAL);
        assertThat(decimal("SELECT exchange_rate FROM "+f.prefix()+"_orders WHERE id=?",f.order())).isEqualByComparingTo("1");
        assertThat(decimal("SELECT total_local FROM "+f.prefix()+"_orders WHERE id=?",f.order())).isEqualByComparingTo(ORIGINAL);
        if(kind.equals("PURCHASE")) assertThat(purchaseOrders.detail(f.order()).getEffectiveFinanceExchangeRate()).isEqualByComparingTo(RATE);
        else assertThat(subcontractOrders.detail(f.order()).getEffectiveFinanceExchangeRate()).isEqualByComparingTo(RATE);
        UUID receipt=receipt(f,"3.125");
        assertThat(decimal("SELECT exchange_rate FROM "+f.prefix()+"_receipts WHERE id=?",receipt)).isEqualByComparingTo(RATE);
        assertThat(decimal("SELECT total_local FROM "+f.prefix()+"_receipts WHERE id=?",receipt)).isEqualByComparingTo(LOCAL);
        approveReceipt(f,receipt);
        assertThat(decimal("SELECT amount_original_local FROM ar_ap_ledger WHERE source_doc_id=? AND direction='AP'",receipt)).isEqualByComparingTo(LOCAL);
        assertThat(db.queryForObject("SELECT finance_approval_case_id FROM "+f.prefix()+"_receipt_items WHERE receipt_id=?",UUID.class,receipt)).isEqualTo(caseId);
        resolveInspection(f,receipt);
        reverseReceipt(f,receipt);
        assertThat(decimal("SELECT COALESCE(SUM(amount_original_local),0) FROM ar_ap_ledger WHERE source_doc_id=? AND status=1 AND direction='AP'",receipt)).isZero();
        assertThat(decimal("SELECT received_qty FROM "+f.prefix()+"_order_items WHERE id=?",f.item())).isZero();
    }

    @Test void warehouseGeneratedReceiptUsesFinancialRateAndReplaysWithoutDuplicateAp(){
        Fixture f=fixture("PURCHASE","3.125",false); UUID caseId=approve(f,RATE);
        var request=new WarehouseArrivalRegisterRequest("fx-warehouse-"+f.order(),"PURCHASE",BusinessTime.today(),f.world().supplierId(),
                f.world().warehouseId(),null,f.world().employeeId(),null,List.of(new WarehouseArrivalRegisterRequest.ArrivalLine(
                f.world().goodsD(),new BigDecimal("3.125"),f.item(),null,f.world().unitId(),BigDecimal.ONE,null)));
        var first=arrivals.register(request); var repeated=arrivals.register(request);
        assertThat(repeated.receiptId()).isEqualTo(first.receiptId());
        assertThat(decimal("SELECT exchange_rate FROM purchase_receipts WHERE id=?",first.receiptId())).isEqualByComparingTo(RATE);
        assertThat(decimal("SELECT amount_original_local FROM ar_ap_ledger WHERE source_doc_id=? AND status=1",first.receiptId())).isEqualByComparingTo(LOCAL);
        assertThat(db.queryForObject("SELECT finance_approval_case_id FROM purchase_receipt_items WHERE receipt_id=?",UUID.class,first.receiptId())).isEqualTo(caseId);
        assertThat(db.queryForObject("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_id=? AND status=1",Integer.class,first.receiptId())).isEqualTo(1);
    }

    @Test void partialReceiptForbidsReconfirmationAtAnotherRateAndKeepsHistoricalAmounts(){
        Fixture f=fixture("PURCHASE","3.125",false); approve(f,RATE);
        UUID first=receipt(f,"1.125"); approveReceipt(f,first);
        BigDecimal posted=decimal("SELECT total_local FROM purchase_receipts WHERE id=?",first);
        purchaseOrders.changeQty(f.order(),new OrderQtyChangeRequest(List.of(new OrderQtyChangeItem(f.item(),new BigDecimal("4.125")))));
        harness.loginAs(f.reviewer()); BatchDecisionItem decision=pending(f);
        assertThatThrownBy(()->finance.approveBatch(List.of(decision),null,new BigDecimal("8.123457"))).isInstanceOf(ApiException.class);
        assertThat(decimal("SELECT total_local FROM purchase_receipts WHERE id=?",first)).isEqualByComparingTo(posted);
        finance.approveBatch(List.of(decision),null,RATE); harness.loginAs(f.world().superAdminUserId());
        UUID second=receipt(f,"3"); approveReceipt(f,second);
        assertThat(decimal("SELECT SUM(r.total_local) FROM purchase_receipts r JOIN purchase_receipt_items i ON i.receipt_id=r.id WHERE i.order_item_id=? AND r.status=1",f.item()))
                .isEqualByComparingTo(new BigDecimal("4.125").multiply(new BigDecimal("13.123457")).multiply(RATE));
        assertThat(decimal("SELECT total_local FROM purchase_receipts WHERE id=?",first)).isEqualByComparingTo(posted);
    }

    @Test void legacyNullFinancialDecisionRetainsContractRateAndStoredLocalRatherThanReestimating(){
        Fixture f=fixture("PURCHASE","3.125",false); UUID caseId=approve(f,BigDecimal.ONE);
        db.update("UPDATE procurement_order_approval_cases SET finance_exchange_rate=NULL,finance_total_local=NULL WHERE id=?",caseId);
        UUID receipt=receipt(f,"3.125"); approveReceipt(f,receipt);
        assertThat(decimal("SELECT total_local FROM purchase_receipts WHERE id=?",receipt)).isEqualByComparingTo(ORIGINAL);
        assertThat(decimal("SELECT amount_original_local FROM ar_ap_ledger WHERE source_doc_id=?",receipt)).isEqualByComparingTo(ORIGINAL);
        assertThat(decimal("SELECT exchange_rate FROM purchase_receipts WHERE id=?",receipt)).isEqualByComparingTo("1");
    }

    @Test void sourcesWithDifferentFinancialRatesRejectAtDraftSaveWithoutInventingMixedAmount(){
        Fixture first=fixture("PURCHASE","3.125",false); approve(first,RATE);
        UUID secondOrder=purchaseOrder(first.world(),first.purchaseSource(),first.currency(),"3.125");
        UUID secondItem=db.queryForObject("SELECT id FROM purchase_order_items WHERE order_id=?",UUID.class,secondOrder);
        Fixture second=new Fixture(first.world(),first.reviewer(),first.currency(),"PURCHASE",secondOrder,secondItem,first.purchaseSource()); approve(second,new BigDecimal("8.123457"));
        var request=purchaseReceipt(first,"1"); var other=new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();
        other.setGoodsId(first.world().goodsD());other.setUnitId(first.world().unitId());other.setUnitRate(BigDecimal.ONE);other.setQty(BigDecimal.ONE);other.setOrderItemId(secondItem);
        request.setItems(List.of(request.getItems().getFirst(),other));
        long before=db.queryForObject("SELECT count(*) FROM purchase_receipts WHERE maker_id=?",Long.class,first.world().employeeId());
        assertThatThrownBy(()->purchaseReceipts.create(request)).isInstanceOf(ApiException.class);
        assertThat(db.queryForObject("SELECT count(*) FROM purchase_receipts WHERE maker_id=?",Long.class,first.world().employeeId())).isEqualTo(before);
    }

    @Test void receiptUnapprovalRepinsTheDecisionAndReapprovalPostsOnceWithoutChangingOriginal(){
        Fixture f=fixture("PURCHASE","3.125",false); UUID caseId=approve(f,RATE);
        UUID original=receipt(f,"3.125"); approveReceipt(f,original);
        resolveInspection(f,original);
        var command=new DocumentUnapprovalService.UnapproveRequest("fx-receipt-unapprove-"+original,"数量与本币对称验算");
        var draft=(com.uten.imp.features.purchase.receipt.dto.ReceiptDetail)unapproval.unapprove("purchaseReceipt",original,command);
        var repeated=(com.uten.imp.features.purchase.receipt.dto.ReceiptDetail)unapproval.unapprove("purchaseReceipt",original,command);
        assertThat(repeated.getId()).isEqualTo(draft.getId());
        assertThat(db.queryForObject("SELECT finance_approval_case_id FROM purchase_receipt_items WHERE receipt_id=?",UUID.class,draft.getId())).isNull();
        approveReceipt(f,draft.getId());
        assertThat(decimal("SELECT total_local FROM purchase_receipts WHERE id=?",original)).isEqualByComparingTo(LOCAL);
        assertThat(decimal("SELECT amount_original_local FROM ar_ap_ledger WHERE source_doc_id=? AND status=1",draft.getId())).isEqualByComparingTo(LOCAL);
        assertThat(db.queryForObject("SELECT finance_approval_case_id FROM purchase_receipt_items WHERE receipt_id=?",UUID.class,draft.getId())).isEqualTo(caseId);
        assertThat(decimal("SELECT received_qty FROM purchase_order_items WHERE id=?",f.item())).isEqualByComparingTo("3.125");
    }

    @Test void purchaseReturnUsesPostedReceiptFinancialAmountsAndReverseRestoresExactStockAndCredit(){
        Fixture f=fixture("PURCHASE","3.125",false); approve(f,RATE);
        UUID receipt=receipt(f,"3.125");approveReceipt(f,receipt);
        ReflectionTestUtils.invokeMethod(harness,"passAndStockPurchaseReceipt",f.world(),receipt,new BigDecimal("3.125"));
        UUID receiptItem=purchaseReceipts.detail(receipt).getItems().getFirst().getId();
        var request=new com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest();request.setBillDate(BusinessTime.today());
        request.setSupplierId(f.world().supplierId());request.setWarehouseId(f.world().warehouseId());request.setCurrencyId(f.currency());
        request.setExchangeRate(RATE);request.setTaxRate(BigDecimal.ZERO);request.setSettlementMethodId(settlement());
        var line=new com.uten.imp.features.purchase.ret.dto.ReturnItemLine();line.setGoodsId(f.world().goodsD());line.setUnitId(f.world().unitId());
        line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal("1.125"));line.setPrice(new BigDecimal("13.123457"));
        line.setReceiptItemId(receiptItem);line.setOrderItemId(f.item());request.setItems(List.of(line));
        UUID returned=returns.create(request).getId();returns.approve(returned);
        BigDecimal credit=new BigDecimal("1.125").multiply(new BigDecimal("13.123457")).multiply(RATE);
        assertThat(decimal("SELECT total_local FROM purchase_returns WHERE id=?",returned)).isEqualByComparingTo(credit);
        assertThat(decimal("SELECT amount_original_local FROM ar_ap_ledger WHERE source_doc_id=? AND status=1",returned)).isEqualByComparingTo(credit.negate());
        assertThat(decimal("SELECT SUM(qty) FROM stock_balances WHERE goods_id=?",f.world().goodsD())).isEqualByComparingTo("2");
        returns.reverse(returned);
        assertThat(decimal("SELECT SUM(qty) FROM stock_balances WHERE goods_id=?",f.world().goodsD())).isEqualByComparingTo("3.125");
        assertThat(decimal("SELECT COALESCE(SUM(amount_original_local),0) FROM ar_ap_ledger WHERE source_doc_id=? AND status=1",returned)).isZero();
        assertThat(decimal("SELECT total_local FROM purchase_receipts WHERE id=?",receipt)).isEqualByComparingTo(LOCAL);
    }

    @Test void forwardMigrationRetainsBookDomainExactIndexesAndExistingResetClassification(){
        assertThat(db.queryForObject("SELECT atttypmod FROM pg_attribute WHERE attrelid='procurement_order_approval_cases'::regclass AND attname='finance_total_local'",Integer.class)).isEqualTo(-1);
        assertThat(db.queryForObject("SELECT public.fn_financial_book_amount_is_exact(292.138692596403125)",Boolean.class)).isTrue();
        assertThat(db.queryForObject("SELECT public.fn_financial_book_amount_is_exact(1e40::numeric)",Boolean.class)).isFalse();
        assertThat(db.queryForObject("SELECT public.fn_financial_book_amount_is_exact(0.1234567890123456789012345678901::numeric)",Boolean.class)).isFalse();
        assertThat(db.queryForList("SELECT indexname FROM pg_indexes WHERE schemaname='public' AND tablename IN ('purchase_receipt_items','subcontract_receipt_items') AND indexdef LIKE '%finance_approval_case_id%' ORDER BY indexname",String.class))
                .containsExactly("idx_purchase_receipt_item_finance_case","idx_subcontract_receipt_item_finance_case");
        assertThat(db.queryForObject("SELECT count(*) FROM pg_constraint WHERE contype='f' AND confrelid='procurement_order_approval_cases'::regclass AND conrelid IN ('purchase_receipt_items'::regclass,'subcontract_receipt_items'::regclass) AND convalidated AND NOT condeferrable",Integer.class)).isEqualTo(2);
        assertThat(db.queryForList("SELECT table_name FROM fn_business_reset_table_policy() WHERE table_name IN ('purchase_receipt_items','subcontract_receipt_items','procurement_order_approval_cases') AND disposition='CLEAR' ORDER BY table_name",String.class))
                .containsExactly("procurement_order_approval_cases","purchase_receipt_items","subcontract_receipt_items");
    }

    private record Fixture(FullChainEndToEndTest.World world,UUID reviewer,UUID currency,String kind,UUID order,UUID item,UUID purchaseSource){
        String prefix(){return kind.equals("PURCHASE")?"purchase":"subcontract";}
    }
    private Fixture fixture(String kind,String qty,boolean base){
        var w=harness.seedWorld("fx-"+UUID.randomUUID()); harness.loginAs(w.superAdminUserId());
        UUID currency=base?db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class):w.currencyId();
        if(!base)db.update("UPDATE currencies SET name='美金',code=? WHERE id=?","USD-FX-"+currency,currency);
        UUID reviewer=harness.createUserWithPerms(w,"fx-reviewer-"+UUID.randomUUID(),"finance_order_approval:view","finance_order_approval:approve");
        harness.loginAs(w.superAdminUserId());
        var request=new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();request.setBillDate(BusinessTime.today());request.setWarehouseId(w.warehouseId());
        var line=new com.uten.imp.features.purchase.request.dto.RequestItemLine();line.setGoodsId(w.goodsD());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal("20"));request.setItems(List.of(line));
        var source=requests.create(request);requests.approve(source.getId());UUID purchaseSource=source.getItems().getFirst().getId();
        UUID order;
        if(kind.equals("PURCHASE")) order=purchaseOrder(w,purchaseSource,currency,qty);
        else{
            UUID material=harness.addSubcontractDirectMaterial(w,w.goodsE(),"1");harness.receiveSubcontractMaterial(w,material,"100");
            var r=new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();r.setBillDate(BusinessTime.today());r.setSupplierId(w.supplierId());r.setWarehouseId(w.warehouseId());r.setCurrencyId(currency);r.setExchangeRate(BigDecimal.ONE);r.setTaxRate(BigDecimal.ZERO);r.setSettlementMethodId(settlement());
            var item=new com.uten.imp.features.subcontract.order.dto.OrderItemLine();item.setGoodsId(w.goodsE());item.setUnitId(w.unitId());item.setUnitRate(BigDecimal.ONE);item.setQty(new BigDecimal(qty));item.setPrice(new BigDecimal("13.123457"));r.setItems(List.of(item));order=subcontractOrders.create(r).getId();
        }
        UUID item=db.queryForObject("SELECT id FROM "+(kind.equals("PURCHASE")?"purchase":"subcontract")+"_order_items WHERE order_id=?",UUID.class,order);
        return new Fixture(w,reviewer,currency,kind,order,item,purchaseSource);
    }
    private UUID purchaseOrder(FullChainEndToEndTest.World w,UUID source,UUID currency,String qty){
        var r=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();r.setBillDate(BusinessTime.today());r.setSupplierId(w.supplierId());r.setWarehouseId(w.warehouseId());r.setCurrencyId(currency);r.setExchangeRate(BigDecimal.ONE);r.setTaxRate(BigDecimal.ZERO);r.setSettlementMethodId(settlement());
        var line=new com.uten.imp.features.purchase.order.dto.OrderItemLine();line.setGoodsId(w.goodsD());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));line.setPrice(new BigDecimal("13.123457"));line.setRequestItemId(source);r.setItems(List.of(line));return purchaseOrders.create(r).getId();
    }
    private UUID settlement(){return db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class);}
    private BatchDecisionItem submit(Fixture f){harness.loginAs(f.world().superAdminUserId());finance.submit(f.kind(),f.order());harness.loginAs(f.reviewer());return pending(f);}
    private BatchDecisionItem pending(Fixture f){
        var caseRow=db.queryForMap("SELECT id,version FROM procurement_order_approval_cases WHERE order_type=? AND order_id=? AND status='PENDING'",f.kind(),f.order());
        UUID id=(UUID)caseRow.get("id");UUID claim=claims.claim("PROCUREMENT_FINANCE_APPROVE",id.toString()).claimId();return new BatchDecisionItem(id,((Number)caseRow.get("version")).longValue(),claim);
    }
    private UUID approve(Fixture f,BigDecimal rate){var decision=submit(f);finance.approveBatch(List.of(decision),null,rate);harness.loginAs(f.world().superAdminUserId());return decision.caseId();}
    private com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest purchaseReceipt(Fixture f,String qty){
        var r=new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();r.setBillDate(BusinessTime.today());r.setSupplierId(f.world().supplierId());r.setWarehouseId(f.world().warehouseId());r.setExchangeRate(BigDecimal.ONE);
        var line=new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();line.setGoodsId(f.world().goodsD());line.setUnitId(f.world().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));line.setPrice(new BigDecimal("13.123457"));line.setOrderItemId(f.item());r.setItems(List.of(line));return r;
    }
    private UUID receipt(Fixture f,String qty){
        if(f.kind().equals("PURCHASE"))return purchaseReceipts.create(purchaseReceipt(f,qty)).getId();
        harness.drawAndIssueSubcontract(f.item(),new BigDecimal(qty),"fx-issued-"+UUID.randomUUID());
        var r=new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();r.setBillDate(BusinessTime.today());r.setSupplierId(f.world().supplierId());r.setWarehouseId(f.world().warehouseId());r.setExchangeRate(BigDecimal.ONE);
        var line=new com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine();line.setGoodsId(f.world().goodsE());line.setUnitId(f.world().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));line.setPrice(new BigDecimal("13.123457"));line.setOrderItemId(f.item());r.setItems(List.of(line));return subcontractReceipts.create(r).getId();
    }
    private void approveReceipt(Fixture f,UUID id){if(f.kind().equals("PURCHASE"))purchaseReceipts.approve(id);else subcontractReceipts.approve(id);}
    private void reverseReceipt(Fixture f,UUID id){if(f.kind().equals("PURCHASE"))purchaseReceipts.reverse(id);else subcontractReceipts.reverse(id);}
    private void resolveInspection(Fixture f,UUID receipt){
        UUID inspection=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type=? AND receipt_id=?",UUID.class,f.kind(),receipt);
        inspections.dispose(f.kind(),receipt,inspection,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                "PASS",null,"真实质检结案后反审", "fx-inspection-"+receipt));
    }
    private BigDecimal decimal(String sql,Object...args){return db.queryForObject(sql,BigDecimal.class,args);}
}
