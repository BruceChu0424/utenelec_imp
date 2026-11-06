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
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
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
        "uten.jwt.secret=fx-regression-isolated-jwt-key-0123456789-abcdef", // gitleaks:allow synthetic test-only cryptographic fixture.
        "uten.crypto.pgp-master-key=fx-regression-isolated-pgp-key-0123456789-abcdef", // gitleaks:allow synthetic test-only cryptographic fixture.
        "uten.crypto.hmac-key=fx-regression-isolated-hmac-key-0123456789-abcdef",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@FinanceScopedChain
class ProcurementFinanceEffectiveExchangeRateEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){ FinanceScopedChainDatabase.register(registry,ProcurementFinanceEffectiveExchangeRateEndToEndTest.class); }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PurchaseRequestService requests;
    @Autowired PurchaseOrderService purchaseOrders;
    @Autowired SubcontractOrderService subcontractOrders;
    @Autowired PurchaseReceiptService purchaseReceipts;
    @Autowired SubcontractReceiptService subcontractReceipts;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired PlatformTransactionManager transactions;
    @Autowired com.fasterxml.jackson.databind.ObjectMapper json;
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

    @Test void pendingPurchaseQuantityRevisionRetainsCaseAndOnlyReservesUntilFreshFinanceDecision() {
        Fixture f=fixture("PURCHASE","3.125",false);
        var stale=submit(f);
        String originalHash=db.queryForObject("SELECT snapshot_hash FROM procurement_order_approval_cases WHERE id=?",String.class,stale.caseId());
        harness.loginAs(f.world().superAdminUserId());
        purchaseOrders.changeQty(f.order(),new OrderQtyChangeRequest(List.of(new OrderQtyChangeItem(f.item(),new BigDecimal("4.1256")))));
        assertThat(decimal("SELECT status FROM purchase_orders WHERE id=?",f.order())).isZero();
        assertThat(decimal("SELECT qty FROM purchase_order_items WHERE id=?",f.item())).isEqualByComparingTo("4.1256");
        assertThat(decimal("SELECT ordered_qty FROM purchase_request_items WHERE id=?",f.purchaseSource())).isZero();
        assertThat(decimal("SELECT alloc_qty FROM purchase_order_item_sources WHERE order_item_id=?",f.item())).isEqualByComparingTo("4.1256");
        assertThat(db.queryForObject("SELECT count(*) FROM procurement_order_approval_cases WHERE order_type='PURCHASE' AND order_id=?",Long.class,f.order())).isEqualTo(1);
        assertThat(decimal("SELECT version FROM procurement_order_approval_cases WHERE id=?",stale.caseId())).isEqualByComparingTo(BigDecimal.valueOf(stale.expectedVersion()+1));
        assertThat(db.queryForObject("SELECT submission_snapshot #>> '{items,0,qty}' FROM procurement_order_approval_cases WHERE id=?",String.class,stale.caseId())).isEqualTo("4.1256");
        assertThat(db.queryForObject("SELECT display_snapshot #>> '{items,0,qty}' FROM procurement_order_approval_cases WHERE id=?",String.class,stale.caseId())).isEqualTo("4.1256");
        assertThat(db.queryForObject("SELECT event_snapshot->>'previousSnapshotHash' FROM procurement_order_approval_events WHERE case_id=? AND event_type='QUANTITY_CHANGED'",String.class,stale.caseId())).isEqualTo(originalHash);
        assertThat(db.queryForObject("SELECT event_snapshot #>> '{previousSubmissionSnapshot,items,0,qty}' FROM procurement_order_approval_events WHERE case_id=? AND event_type='QUANTITY_CHANGED'",String.class,stale.caseId())).isEqualTo("3.125");
        assertThat(db.queryForObject("SELECT count(*) FROM inbound_expectations WHERE order_type='PURCHASE' AND order_id=?",Long.class,f.order())).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM production_material_supply_pegs WHERE supply_type='PURCHASE_ORDER_ITEM' AND supply_item_id=?",Long.class,f.item())).isZero();
        harness.loginAs(f.reviewer());
        assertThatThrownBy(()->finance.approveBatch(List.of(stale),null,RATE)).isInstanceOf(ApiException.class);
        var fresh=pending(f);
        assertThat(fresh.caseId()).isEqualTo(stale.caseId());
        finance.approveBatch(List.of(fresh),null,RATE);
        assertThat(decimal("SELECT status FROM purchase_orders WHERE id=?",f.order())).isEqualByComparingTo("1");
        assertThat(decimal("SELECT ordered_qty FROM purchase_request_items WHERE id=?",f.purchaseSource())).isEqualByComparingTo("4.1256");
        assertThat(decimal("SELECT ordered_qty FROM inbound_expectation_items WHERE order_item_id=?",f.item())).isEqualByComparingTo("4.1256");
        assertThat(db.queryForObject("SELECT count(*) FROM procurement_order_qty_change_logs WHERE order_id=? AND case_id=?",Long.class,f.order(),stale.caseId())).isEqualTo(1);
    }

    @Test void pendingQuantityProofRejectsMissingNullNonArrayAndDuplicateOrOmittedItemIdentities() {
        Fixture base=fixture("PURCHASE","3.125",false);
        UUID order=purchaseOrder(base.world(),base.purchaseSource(),base.currency(),"3.125",true);
        UUID item=db.queryForObject("SELECT id FROM purchase_order_items WHERE order_id=? ORDER BY line_no LIMIT 1",UUID.class,order);
        Fixture f=new Fixture(base.world(),base.reviewer(),base.currency(),"PURCHASE",order,item,base.purchaseSource());
        var decision=submit(f);
        harness.loginAs(f.world().superAdminUserId());
        new TransactionTemplate(transactions).executeWithoutResult(transaction -> {
            String before=db.queryForObject("SELECT to_jsonb(c)::text FROM procurement_order_approval_cases c WHERE id=?",String.class,decision.caseId());
            purchaseOrders.changeQty(order,new OrderQtyChangeRequest(List.of(new OrderQtyChangeItem(item,new BigDecimal("4.1256")))));
            String after=db.queryForObject("SELECT to_jsonb(c)::text FROM procurement_order_approval_cases c WHERE id=?",String.class,decision.caseId());
            assertThat(db.queryForObject("SELECT fn_is_pending_purchase_case_qty_revision(CAST(? AS jsonb),CAST(? AS jsonb))",Boolean.class,before,after)).isTrue();
            for(String replacement:List.of("null","{}","[null]")) {
                assertThat(db.queryForObject("SELECT fn_is_pending_purchase_case_qty_revision(CAST(? AS jsonb),jsonb_set(CAST(? AS jsonb),'{submission_snapshot,items}',CAST(? AS jsonb)))",Boolean.class,before,after,replacement)).isFalse();
            }
            assertThat(db.queryForObject("SELECT fn_is_pending_purchase_case_qty_revision(CAST(? AS jsonb),CAST(? AS jsonb) #- '{submission_snapshot,items}')",Boolean.class,before,after)).isFalse();
            assertThat(db.queryForObject("""
                    SELECT fn_is_pending_purchase_case_qty_revision(CAST(? AS jsonb),jsonb_set(CAST(? AS jsonb),
                      '{submission_snapshot,items}',jsonb_build_array(CAST(? AS jsonb) #> '{submission_snapshot,items,0}',
                                                                  CAST(? AS jsonb) #> '{submission_snapshot,items,0}')))
                    """,Boolean.class,before,after,after,after)).isFalse();
        });
        assertThat(db.queryForObject("SELECT pg_get_triggerdef(oid) FROM pg_trigger WHERE tgname='trg_procurement_approval_display_snapshot_immutable'",String.class))
                .contains("display_snapshot", "submission_snapshot", "snapshot_hash", "amount_snapshot");
        assertThatThrownBy(()->db.update("UPDATE procurement_order_approval_cases SET submission_snapshot=jsonb_set(submission_snapshot,'{items}', 'null'::jsonb) WHERE id=?",decision.caseId()))
                .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
    }

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
        String frozenReceiptFacts=postedReceiptFacts(first);
        purchaseOrders.changeQty(f.order(),new OrderQtyChangeRequest(List.of(new OrderQtyChangeItem(f.item(),new BigDecimal("4.125")))));
        assertThat(postedReceiptFacts(first)).isEqualTo(frozenReceiptFacts);
        harness.loginAs(f.reviewer()); BatchDecisionItem decision=pending(f);
        assertThatThrownBy(()->finance.approveBatch(List.of(decision),null,new BigDecimal("8.123457"))).isInstanceOf(ApiException.class);
        assertThat(decimal("SELECT total_local FROM purchase_receipts WHERE id=?",first)).isEqualByComparingTo(posted);
        finance.approveBatch(List.of(decision),null,RATE); harness.loginAs(f.world().superAdminUserId());
        assertThat(postedReceiptFacts(first)).isEqualTo(frozenReceiptFacts);
        UUID second=receipt(f,"3"); approveReceipt(f,second);
        assertThat(decimal("SELECT SUM(r.total_local) FROM purchase_receipts r JOIN purchase_receipt_items i ON i.receipt_id=r.id WHERE i.order_item_id=? AND r.status=1",f.item()))
                .isEqualByComparingTo(new BigDecimal("4.125").multiply(new BigDecimal("13.123457")).multiply(RATE));
        assertThat(decimal("SELECT total_local FROM purchase_receipts WHERE id=?",first)).isEqualByComparingTo(posted);
    }

    private String postedReceiptFacts(UUID receipt) {
        return db.queryForObject("""
            SELECT jsonb_build_object(
                'header',(SELECT to_jsonb(r) FROM purchase_receipts r WHERE id=?),
                'lines',(SELECT jsonb_agg(to_jsonb(i) ORDER BY id) FROM purchase_receipt_items i WHERE receipt_id=?),
                'ledger',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM ar_ap_ledger a WHERE source_doc_id=?),
                'vouchers',(SELECT jsonb_agg(to_jsonb(v) ORDER BY id) FROM gl_vouchers v WHERE source_doc_id=?),
                'entries',(SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id) FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id WHERE v.source_doc_id=?),
                'stock',(SELECT jsonb_agg(to_jsonb(m) ORDER BY id) FROM stock_movements m))::text
            """,String.class,receipt,receipt,receipt,receipt,receipt);
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
        ReflectionTestUtils.invokeMethod(harness,"passAndStockPurchaseReceipt",f.world(),original,new BigDecimal("3.125"));
        assertThat(decimal("SELECT sum(qty) FROM stock_balances WHERE goods_id=?",f.world().goodsD())).isEqualByComparingTo("3.125");
        String frozenQuantity=receiptQuantityFacts(original);
        String originalStock=db.queryForObject("SELECT jsonb_agg(to_jsonb(m) ORDER BY id)::text FROM stock_movements m WHERE goods_id=?",String.class,f.world().goodsD());
        assertThat(originalStock).isNotNull().isNotEqualTo("[]");
        String originalEntries=db.queryForObject("SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.id),'[]')::text FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id WHERE v.source_doc_id=?",String.class,original);
        var command=new DocumentUnapprovalService.UnapproveRequest("fx-receipt-unapprove-"+original,"数量与本币对称验算");
        var draft=(com.uten.imp.features.purchase.receipt.dto.ReceiptDetail)unapproval.unapprove("purchaseReceipt",original,command);
        var repeated=(com.uten.imp.features.purchase.receipt.dto.ReceiptDetail)unapproval.unapprove("purchaseReceipt",original,command);
        assertThat(repeated.getId()).isEqualTo(draft.getId());
        assertThat(receiptQuantityFacts(draft.getId())).isEqualTo(frozenQuantity);
        assertThat(receiptQuantityFacts(original)).isEqualTo(frozenQuantity);
        assertThat(db.queryForObject("SELECT unapproval_source_item_id FROM purchase_receipt_items WHERE receipt_id=?",UUID.class,draft.getId()))
                .isEqualTo(db.queryForObject("SELECT id FROM purchase_receipt_items WHERE receipt_id=?",UUID.class,original));
        assertThat(decimal("SELECT coalesce(sum(qty),0) FROM stock_balances WHERE goods_id=?",f.world().goodsD())).isZero();
        assertThat(db.queryForObject("SELECT finance_approval_case_id FROM purchase_receipt_items WHERE receipt_id=?",UUID.class,draft.getId())).isNull();
        approveReceipt(f,draft.getId());
        ReflectionTestUtils.invokeMethod(harness,"passAndStockPurchaseReceipt",f.world(),draft.getId(),new BigDecimal("3.125"));
        assertThat(decimal("SELECT total_local FROM purchase_receipts WHERE id=?",original)).isEqualByComparingTo(LOCAL);
        assertThat(decimal("SELECT amount_original_local FROM ar_ap_ledger WHERE source_doc_id=? AND status=1",draft.getId())).isEqualByComparingTo(LOCAL);
        assertThat(db.queryForObject("SELECT finance_approval_case_id FROM purchase_receipt_items WHERE receipt_id=?",UUID.class,draft.getId())).isEqualTo(caseId);
        assertThat(decimal("SELECT received_qty FROM purchase_order_items WHERE id=?",f.item())).isEqualByComparingTo("3.125");
        assertThat(decimal("SELECT sum(qty) FROM stock_balances WHERE goods_id=?",f.world().goodsD())).isEqualByComparingTo("3.125");
        assertThat(receiptQuantityFacts(original)).isEqualTo(frozenQuantity);
        assertThat(receiptQuantityFacts(draft.getId())).isEqualTo(frozenQuantity);
        assertThat(db.queryForObject("SELECT jsonb_agg(to_jsonb(m) ORDER BY id)::text FROM stock_movements m WHERE id IN(SELECT (value->>'id')::uuid FROM jsonb_array_elements(?::jsonb))",String.class,originalStock)).isEqualTo(originalStock);
        assertThat(db.queryForObject("SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY id),'[]')::text FROM gl_entries e WHERE id IN(SELECT (value->>'id')::uuid FROM jsonb_array_elements(?::jsonb))",String.class,originalEntries)).isEqualTo(originalEntries);
    }

    private String receiptQuantityFacts(UUID receipt) {
        return db.queryForObject("""
            SELECT to_jsonb(q)::text FROM (SELECT goods_id,order_item_id,unit_id,unit_rate,qty,
                quantity_semantics,gift_qty,charged_base_qty,gift_base_qty,replacement_intent,gift_replacement_intent,
                quantity_adoption_version,quantity_precision_policy,price,amount_original,amount_local
                FROM purchase_receipt_items WHERE receipt_id=?)q
            """,String.class,receipt);
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
    }

    @ParameterizedTest @ValueSource(strings={"PURCHASE","SUBCONTRACT"})
    void financialTaxFollowsReceiptsWithoutRewritingSubmittedTermsAndCannotRevaluePostedReceipts(String kind) {
        Fixture f=fixture(kind,"3.125",false);
        var decision=submit(f);
        String hash=db.queryForObject("SELECT snapshot_hash FROM procurement_order_approval_cases WHERE id=?",String.class,decision.caseId());
        finance.approveBatch(List.of(decision),"核定税率",RATE,new BigDecimal("13.1234"));
        assertThat(finance.review(decision.caseId()).financeTaxRate()).isEqualByComparingTo("13.1234");
        assertThat(finance.review(decision.caseId()).taxRate()).isZero();
        assertThat(decimal("SELECT tax_rate FROM "+f.prefix()+"_orders WHERE id=?",f.order())).isZero();
        assertThat(db.queryForObject("SELECT snapshot_hash FROM procurement_order_approval_cases WHERE id=?",String.class,decision.caseId())).isEqualTo(hash);
        assertThat(db.queryForObject("SELECT event_snapshot->>'financeTaxRate' FROM procurement_order_approval_events WHERE case_id=? AND event_type='APPROVED'",String.class,decision.caseId())).isEqualTo("13.1234");
        harness.loginAs(f.world().superAdminUserId());
        if(kind.equals("PURCHASE")) assertThat(purchaseOrders.detail(f.order()).getTaxRate()).isEqualByComparingTo("13.1234");
        else assertThat(subcontractOrders.detail(f.order()).getTaxRate()).isEqualByComparingTo("13.1234");
        UUID received=receipt(f,"1.125");
        assertThat(decimal("SELECT tax_rate FROM "+f.prefix()+"_receipts WHERE id=?",received)).isEqualByComparingTo("13.1234");
        approveReceipt(f,received);
        assertThat(decimal("SELECT total_original FROM "+f.prefix()+"_receipts WHERE id=?",received)).isEqualByComparingTo(new BigDecimal("1.125").multiply(new BigDecimal("13.123457")));
        if(kind.equals("PURCHASE")) purchaseOrders.changeQty(f.order(),new OrderQtyChangeRequest(List.of(new OrderQtyChangeItem(f.item(),new BigDecimal("4.125")))));
        else subcontractOrders.changeQty(f.order(),new OrderQtyChangeRequest(List.of(new OrderQtyChangeItem(f.item(),new BigDecimal("4.125")))));
        harness.loginAs(f.reviewer());
        var repeat=pending(f);
        assertThat(finance.review(repeat.caseId()).financeTaxRate()).isNull();
        assertThat(finance.review(repeat.caseId()).referenceFinanceTaxRate()).isEqualByComparingTo("13.1234");
        assertThat(finance.review(repeat.caseId()).referenceFinanceExchangeRate()).isEqualByComparingTo(RATE);
        assertThat(finance.review(decision.caseId()).referenceFinanceTaxRate()).isNull();
        assertThatThrownBy(()->finance.approveBatch(List.of(repeat),null,RATE,new BigDecimal("9"))).isInstanceOf(ApiException.class);
        assertThat(db.queryForObject("SELECT status FROM procurement_order_approval_cases WHERE id=?",String.class,repeat.caseId())).isEqualTo("PENDING");
        finance.approveBatch(List.of(repeat),null,RATE);
        assertThat(decimal("SELECT finance_tax_rate FROM procurement_order_approval_cases WHERE id=?",repeat.caseId())).isEqualByComparingTo("13.1234");
        assertThat(decimal("SELECT tax_rate FROM "+f.prefix()+"_receipts WHERE id=?",received)).isEqualByComparingTo("13.1234");
    }

    @Test void warehouseGeneratedReceiptUsesFinancialTaxAndMixedTaxSourcesCannotSave() {
        Fixture f=fixture("PURCHASE","3.125",false);
        var decision=submit(f);finance.approveBatch(List.of(decision),null,RATE,new BigDecimal("13"));
        harness.loginAs(f.world().superAdminUserId());
        var request=new WarehouseArrivalRegisterRequest("tax-arrival-"+f.order(),"PURCHASE",BusinessTime.today(),f.world().supplierId(),
                f.world().warehouseId(),null,f.world().employeeId(),null,List.of(new WarehouseArrivalRegisterRequest.ArrivalLine(
                f.world().goodsD(),new BigDecimal("1.125"),f.item(),null,f.world().unitId(),BigDecimal.ONE,null)));
        var arrival=arrivals.register(request);
        assertThat(decimal("SELECT tax_rate FROM purchase_receipts WHERE id=?",arrival.receiptId())).isEqualByComparingTo("13");
        UUID otherOrder=purchaseOrder(f.world(),f.purchaseSource(),f.currency(),"3.125");
        UUID otherItem=db.queryForObject("SELECT id FROM purchase_order_items WHERE order_id=?",UUID.class,otherOrder);
        Fixture other=new Fixture(f.world(),f.reviewer(),f.currency(),"PURCHASE",otherOrder,otherItem,f.purchaseSource());
        approve(other,RATE);
        var receipt=purchaseReceipt(f,"1");
        var line=new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();
        line.setGoodsId(f.world().goodsD());line.setUnitId(f.world().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(BigDecimal.ONE);line.setOrderItemId(otherItem);
        receipt.setItems(List.of(receipt.getItems().getFirst(),line));
        assertThatThrownBy(()->purchaseReceipts.create(receipt)).isInstanceOf(ApiException.class);
    }

    @ParameterizedTest @org.junit.jupiter.params.provider.MethodSource("unitPriceDomainCases")
    void financialUnitPriceBoundarySavesThroughRealOrderReviewAndReceipt(String kind,String rawPrice) {
        BigDecimal price=new BigDecimal(rawPrice);
        Fixture f=fixture(kind,"1",true,price);
        assertThat(decimal("SELECT price FROM "+f.prefix()+"_order_items WHERE id=?",f.item())).isEqualByComparingTo(price);
        assertThat(decimal("SELECT total_original FROM "+f.prefix()+"_orders WHERE id=?",f.order())).isEqualByComparingTo(price);
        UUID decision=approve(f,BigDecimal.ONE);
        String orderBefore=db.queryForObject("SELECT to_jsonb(i)::text FROM "+f.prefix()+"_order_items i WHERE id=?",String.class,f.item());
        UUID receipt=receipt(f,"1");approveReceipt(f,receipt);
        assertThat(decimal("SELECT price FROM "+f.prefix()+"_receipt_items WHERE receipt_id=?",receipt)).isEqualByComparingTo(price);
        assertThat(decimal("SELECT total_original FROM "+f.prefix()+"_receipts WHERE id=?",receipt)).isEqualByComparingTo(price);
        assertThat(decimal("SELECT total_local FROM "+f.prefix()+"_receipts WHERE id=?",receipt)).isEqualByComparingTo(price);
        assertThat(decimal("SELECT amount_original_local FROM ar_ap_ledger WHERE source_doc_id=? AND status=1",receipt)).isEqualByComparingTo(price);
        assertThat(db.queryForObject("SELECT finance_approval_case_id FROM "+f.prefix()+"_receipt_items WHERE receipt_id=?",UUID.class,receipt)).isEqualTo(decision);
        // Receipt counters may advance; the submitted/approved price and all
        // noncumulative commercial source facts keep their original values.
        assertThat(db.queryForObject("SELECT (to_jsonb(i)-ARRAY['received_qty','issued_qty','updated_at','updated_by'])::text FROM "+f.prefix()+"_order_items i WHERE id=?",String.class,f.item()))
            .isEqualTo(db.queryForObject("SELECT (?::jsonb-ARRAY['received_qty','issued_qty','updated_at','updated_by'])::text",String.class,orderBefore));
    }
    static java.util.stream.Stream<org.junit.jupiter.params.provider.Arguments> unitPriceDomainCases() {
        return java.util.stream.Stream.of("PURCHASE","SUBCONTRACT").flatMap(kind->java.util.stream.Stream.of(
            "9999999999999999999999999999999999999999.123456789012345678901234","0.000000000000000000000001")
            .map(price->org.junit.jupiter.params.provider.Arguments.of(kind,price)));
    }

    @ParameterizedTest @ValueSource(strings={"PURCHASE","SUBCONTRACT"})
    void savedReferenceChoiceSurvivesReviewSameInputSaveAndReceiptTailWithoutAnotherReferenceChoice(String kind) {
        BigDecimal total=new BigDecimal("10.1234567891");
        Fixture original=precision("money.reference-unit-price",24,"DOWN",()->fixture(kind,"3",true,null,total));
        String proof=referencePolicy(original);
        var parsed=referenceTree(proof);
        assertThat(parsed.path("mode").asText()).isEqualTo("SELECTED");
        assertThat(parsed.path("precisionPolicy").path("choices").path("money.reference-unit-price").path("scale").asInt()).isEqualTo(24);
        assertThat(parsed.path("referencePrice").asText()).isEqualTo("3.374485596366666666666666");
        Fixture f=saveSameTotalInput(original,"3",total); // The original saved choice is authoritative.
        String savedProof=referencePolicy(f);
        if(f.item().equals(original.item()))assertThat(savedProof).isEqualTo(proof);
        else{
            assertThat(db.queryForObject("SELECT count(*) FROM "+f.prefix()+"_order_items WHERE id=?",Integer.class,original.item())).isZero();
            assertThat(db.queryForObject("SELECT (payload->'reference_price_precision_policy')::text FROM business_record_history WHERE source_table=? AND source_id=? AND parent_id=? AND operation='DELETE' ORDER BY id DESC LIMIT 1",String.class,f.prefix()+"_order_items",original.item().toString(),f.order().toString())).isEqualTo(proof);
            var newAdoption=referenceTree(savedProof);
            for(String field:List.of("mode","totalInput","quantity","referencePrice","unitId","unitRate","precisionPolicy"))
                assertThat(newAdoption.get(field)).isEqualTo(parsed.get(field));
        }
        UUID reviewed=approve(f,BigDecimal.ONE); // No current reference choice.
        assertThat(referencePolicy(f)).isEqualTo(savedProof);
        assertThatThrownBy(()->db.update("UPDATE "+f.prefix()+"_order_items SET reference_price_precision_policy=jsonb_set(reference_price_precision_policy,'{mode}','\"EXACT\"') WHERE id=?",f.item()))
            .hasRootCauseInstanceOf(org.postgresql.util.PSQLException.class)
            .hasMessageContaining("saved reference price proof cannot be independently replaced")
            .rootCause().isInstanceOfSatisfying(java.sql.SQLException.class,
                sql -> assertThat(sql.getSQLState()).isEqualTo("55000"));
        assertThat(referencePolicy(f)).isEqualTo(savedProof);
        UUID first=precision("money.cumulative-share",24,"DOWN",()->receipt(f,"1"));precision("money.cumulative-share",24,"DOWN",()->{approveReceipt(f,first);return null;});
        UUID tail=receipt(f,"2");approveReceipt(f,tail);
        assertThat(decimal("SELECT sum(amount_original_local) FROM ar_ap_ledger WHERE source_doc_id IN(?,?) AND status=1",first,tail)).isEqualByComparingTo(total);
        assertThat(decimal("SELECT total_original FROM "+f.prefix()+"_orders WHERE id=?",f.order())).isEqualByComparingTo(total);
        assertThat(decimal("SELECT price FROM "+f.prefix()+"_order_items WHERE id=?",f.item())).isEqualByComparingTo("3.374485596366666666666666");
        assertThat(referencePolicy(f)).isEqualTo(savedProof);
        assertThat(db.queryForObject("SELECT count(*) FROM "+f.prefix()+"_receipt_items WHERE receipt_id IN(?,?) AND finance_approval_case_id=?",Integer.class,first,tail,reviewed)).isEqualTo(2);
    }

    @ParameterizedTest @ValueSource(strings={"PURCHASE","SUBCONTRACT"})
    void quantityRevisionsKeepTheOriginalDownReferenceAndFreezeOnlyTheNewTotalRatio(String kind) {
        Fixture f=precision("money.reference-unit-price",2,"DOWN",()->fixture(kind,"6",true,null,BigDecimal.ONE));
        String original=referencePolicy(f);approve(f,BigDecimal.ONE);
        precision("money.reference-unit-price",2,"HALF_UP",()->{changeQuantity(f,"12");return null;});
        assertThat(decimal("SELECT price FROM "+f.prefix()+"_order_items WHERE id=?",f.item())).isEqualByComparingTo("0.16");
        assertThat(decimal("SELECT total_amount_input FROM "+f.prefix()+"_order_items WHERE id=?",f.item())).isEqualByComparingTo("2");
        var first=referenceTree(referencePolicy(f));
        assertThat(first.path("revisionMode").asText()).isEqualTo("EXACT");
        assertThat(first.path("basis").path("reference_price_precision_policy")).isEqualTo(referenceTree(original));
        approveReconfirmation(f);
        precision("money.revised-total",24,"DOWN",()->{changeQuantity(f,"5");return null;});
        var second=referenceTree(referencePolicy(f));
        assertThat(second.path("revisionMode").asText()).isEqualTo("SELECTED");
        assertThat(second.path("revisionPolicy").path("choices").path("money.revised-total").path("scale").asInt()).isEqualTo(24);
        assertThat(second.path("basis")).isEqualTo(first.path("basis"));
        assertThat(decimal("SELECT total_amount_input FROM "+f.prefix()+"_order_items WHERE id=?",f.item())).isEqualByComparingTo("0.833333333333333333333333");
        assertThat(decimal("SELECT price FROM "+f.prefix()+"_order_items WHERE id=?",f.item())).isEqualByComparingTo("0.16");
        approveReconfirmation(f);
        assertThat(db.queryForObject("SELECT fn_procurement_reference_price_matches(to_jsonb(i)) FROM "+f.prefix()+"_order_items i WHERE id=?",Boolean.class,f.item())).isTrue();
        assertThat(db.queryForObject("SELECT count(*) FROM procurement_order_source_revisions WHERE order_id=?",Integer.class,f.order())).isEqualTo(2);
        String revisedProof=referencePolicy(f);
        UUID firstReceipt=precision("money.cumulative-share",24,"DOWN",()->receipt(f,"1"));precision("money.cumulative-share",24,"DOWN",()->{approveReceipt(f,firstReceipt);return null;});
        UUID remainingReceipt=receipt(f,"4");approveReceipt(f,remainingReceipt);
        assertThat(decimal("SELECT sum(amount_original_local) FROM ar_ap_ledger WHERE source_doc_id IN(?,?) AND status=1",firstReceipt,remainingReceipt))
            .isEqualByComparingTo("0.833333333333333333333333");
        assertThat(referencePolicy(f)).isEqualTo(revisedProof);
        assertThat(decimal("SELECT price FROM "+f.prefix()+"_order_items WHERE id=?",f.item())).isEqualByComparingTo("0.16");
    }

    @ParameterizedTest @org.junit.jupiter.params.provider.MethodSource("referenceSuccessorCases")
    void orderSuccessorsInheritTheSavedReferencePolicyAndReviewWithoutChoosingItAgain(String kind,boolean revised) {
        Fixture f=precision("money.reference-unit-price",2,"DOWN",()->fixture(kind,"6",true,null,BigDecimal.ONE));
        approve(f,BigDecimal.ONE);
        if(revised){precision("money.reference-unit-price",2,"HALF_UP",()->{changeQuantity(f,"12");return null;});approveReconfirmation(f);}
        String original=referencePolicy(f);
        String family=kind.equals("PURCHASE")?"purchaseOrder":"subcontractOrder";
        var command=new DocumentUnapprovalService.UnapproveRequest("reference-successor-"+f.order(),"原金额与参考价采用事实保全");
        unapproval.unapprove(family,f.order(),command);
        UUID draft=db.queryForObject("SELECT draft_id FROM document_unapprovals WHERE family=? AND original_id=?",UUID.class,family,f.order());
        UUID item=db.queryForObject("SELECT id FROM "+f.prefix()+"_order_items WHERE order_id=?",UUID.class,draft);
        Fixture inherited=new Fixture(f.world(),f.reviewer(),f.currency(),f.kind(),draft,item,f.purchaseSource());
        assertThat(referencePolicy(inherited)).isEqualTo(original);
        assertThat(db.queryForObject("SELECT unapproval_source_item_id FROM "+f.prefix()+"_order_items WHERE id=?",UUID.class,item)).isEqualTo(f.item());
        unapproval.unapprove(family,f.order(),command);
        assertThat(db.queryForObject("SELECT count(*) FROM document_unapprovals WHERE family=? AND original_id=?",Integer.class,family,f.order())).isEqualTo(1);
        approve(inherited,BigDecimal.ONE);
        assertThat(referencePolicy(inherited)).isEqualTo(original);
        assertThat(referencePolicy(f)).isEqualTo(original);
        assertThat(decimal("SELECT price FROM "+f.prefix()+"_order_items WHERE id=?",f.item())).isEqualByComparingTo("0.16");
    }
    static java.util.stream.Stream<org.junit.jupiter.params.provider.Arguments> referenceSuccessorCases(){
        return java.util.stream.Stream.of("PURCHASE","SUBCONTRACT").flatMap(kind->java.util.stream.Stream.of(false,true)
            .map(revised->org.junit.jupiter.params.provider.Arguments.of(kind,revised)));
    }

    private String referencePolicy(Fixture f){return db.queryForObject("SELECT reference_price_precision_policy::text FROM "+f.prefix()+"_order_items WHERE id=?",String.class,f.item());}
    private com.fasterxml.jackson.databind.JsonNode referenceTree(String stored){
        try{return com.uten.imp.common.finance.FinancialJsonResults.tree(json,stored);}catch(com.fasterxml.jackson.core.JsonProcessingException invalid){throw new AssertionError(invalid);}
    }
    private void changeQuantity(Fixture f,String qty){
        var request=new OrderQtyChangeRequest(List.of(new OrderQtyChangeItem(f.item(),new BigDecimal(qty))));
        if(f.kind().equals("PURCHASE"))purchaseOrders.changeQty(f.order(),request);else subcontractOrders.changeQty(f.order(),request);
    }
    private void approveReconfirmation(Fixture f){harness.loginAs(f.reviewer());finance.approveBatch(List.of(pending(f)),null,BigDecimal.ONE);harness.loginAs(f.world().superAdminUserId());}
    @SuppressWarnings("try")
    private <T>T precision(String purpose,int scale,String rounding,java.util.function.Supplier<T> action){
        try(var selected=com.uten.imp.common.finance.BusinessPrecisionContext.use(java.util.Map.of(purpose,new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(scale,rounding)))){return action.get();}
        catch(RuntimeException|Error failure){throw failure;}catch(Exception failure){throw new AssertionError(failure);}
    }
    private Fixture saveSameTotalInput(Fixture f,String qty,BigDecimal total){
        UUID item;
        if(f.kind().equals("PURCHASE")){
            var request=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(f.world().supplierId());request.setWarehouseId(f.world().warehouseId());request.setCurrencyId(f.currency());request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);request.setSettlementMethodId(settlement());
            var line=new com.uten.imp.features.purchase.order.dto.OrderItemLine();line.setId(f.item());line.setLineNo(1);line.setGoodsId(f.world().goodsD());line.setUnitId(f.world().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));line.setTotalAmountInput(total);line.setRequestItemId(f.purchaseSource());request.setItems(List.of(line));item=purchaseOrders.update(f.order(),request).getItems().getFirst().getId();
        }else{
            var request=new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(f.world().supplierId());request.setWarehouseId(f.world().warehouseId());request.setCurrencyId(f.currency());request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);request.setSettlementMethodId(settlement());
            var line=new com.uten.imp.features.subcontract.order.dto.OrderItemLine();line.setId(f.item());line.setLineNo(1);line.setGoodsId(f.world().goodsE());line.setUnitId(f.world().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));line.setTotalAmountInput(total);request.setItems(List.of(line));item=subcontractOrders.update(f.order(),request).getItems().getFirst().getId();
        }
        return new Fixture(f.world(),f.reviewer(),f.currency(),f.kind(),f.order(),item,f.purchaseSource());
    }

    private record Fixture(FullChainEndToEndTest.World world,UUID reviewer,UUID currency,String kind,UUID order,UUID item,UUID purchaseSource){
        String prefix(){return kind.equals("PURCHASE")?"purchase":"subcontract";}
    }
    private Fixture fixture(String kind,String qty,boolean base){
        return fixture(kind,qty,base,new BigDecimal("13.123457"));
    }
    private Fixture fixture(String kind,String qty,boolean base,BigDecimal price){
        return fixture(kind,qty,base,price,null);
    }
    private Fixture fixture(String kind,String qty,boolean base,BigDecimal price,BigDecimal totalInput){
        var w=harness.seedWorld("fx-"+UUID.randomUUID()); harness.loginAs(w.superAdminUserId());
        UUID currency=base?db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class):w.currencyId();
        if(!base)db.update("UPDATE currencies SET name='美金',code=? WHERE id=?","USD-FX-"+currency,currency);
        UUID reviewer=harness.createUserWithPerms(w,"fx-reviewer-"+UUID.randomUUID(),"finance_order_approval:view","finance_order_approval:approve");
        harness.loginAs(w.superAdminUserId());
        var request=new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();request.setBillDate(BusinessTime.today());request.setWarehouseId(w.warehouseId());
        var line=new com.uten.imp.features.purchase.request.dto.RequestItemLine();line.setGoodsId(w.goodsD());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal("20"));request.setItems(List.of(line));
        var source=requests.create(request);requests.approve(source.getId());UUID purchaseSource=source.getItems().getFirst().getId();
        UUID order;
        if(kind.equals("PURCHASE")) order=purchaseOrder(w,purchaseSource,currency,qty,false,price,totalInput);
        else{
            UUID material=harness.addSubcontractDirectMaterial(w,w.goodsE(),"1");harness.receiveSubcontractMaterial(w,material,"100");
            var r=new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();r.setBillDate(BusinessTime.today());r.setSupplierId(w.supplierId());r.setWarehouseId(w.warehouseId());r.setCurrencyId(currency);r.setExchangeRate(BigDecimal.ONE);r.setTaxRate(BigDecimal.ZERO);r.setSettlementMethodId(settlement());
            var item=new com.uten.imp.features.subcontract.order.dto.OrderItemLine();item.setGoodsId(w.goodsE());item.setUnitId(w.unitId());item.setUnitRate(BigDecimal.ONE);item.setQty(new BigDecimal(qty));item.setPrice(price);item.setTotalAmountInput(totalInput);r.setItems(List.of(item));order=subcontractOrders.create(r).getId();
        }
        UUID item=db.queryForObject("SELECT id FROM "+(kind.equals("PURCHASE")?"purchase":"subcontract")+"_order_items WHERE order_id=?",UUID.class,order);
        return new Fixture(w,reviewer,currency,kind,order,item,purchaseSource);
    }
    private UUID purchaseOrder(FullChainEndToEndTest.World w,UUID source,UUID currency,String qty){
        return purchaseOrder(w,source,currency,qty,false);
    }
    private UUID purchaseOrder(FullChainEndToEndTest.World w,UUID source,UUID currency,String qty,boolean twoLines){
        return purchaseOrder(w,source,currency,qty,twoLines,new BigDecimal("13.123457"));
    }
    private UUID purchaseOrder(FullChainEndToEndTest.World w,UUID source,UUID currency,String qty,boolean twoLines,BigDecimal price){
        return purchaseOrder(w,source,currency,qty,twoLines,price,null);
    }
    private UUID purchaseOrder(FullChainEndToEndTest.World w,UUID source,UUID currency,String qty,boolean twoLines,BigDecimal price,BigDecimal totalInput){
        var r=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();r.setBillDate(BusinessTime.today());r.setSupplierId(w.supplierId());r.setWarehouseId(w.warehouseId());r.setCurrencyId(currency);r.setExchangeRate(BigDecimal.ONE);r.setTaxRate(BigDecimal.ZERO);r.setSettlementMethodId(settlement());
        var lines=new java.util.ArrayList<com.uten.imp.features.purchase.order.dto.OrderItemLine>();
        for(int i=0;i<(twoLines?2:1);i++) {
            var line=new com.uten.imp.features.purchase.order.dto.OrderItemLine();line.setGoodsId(w.goodsD());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));line.setPrice(price);line.setTotalAmountInput(totalInput);line.setRequestItemId(source);lines.add(line);
        }
        r.setItems(lines);return purchaseOrders.create(r).getId();
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
        var line=new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();line.setGoodsId(f.world().goodsD());line.setUnitId(f.world().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));line.setPrice(decimal("SELECT price FROM purchase_order_items WHERE id=?",f.item()));line.setOrderItemId(f.item());r.setItems(List.of(line));return r;
    }
    private UUID receipt(Fixture f,String qty){
        if(f.kind().equals("PURCHASE"))return purchaseReceipts.create(purchaseReceipt(f,qty)).getId();
        harness.drawAndIssueSubcontract(f.item(),new BigDecimal(qty),"fx-issued-"+UUID.randomUUID());
        var r=new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();r.setBillDate(BusinessTime.today());r.setSupplierId(f.world().supplierId());r.setWarehouseId(f.world().warehouseId());r.setExchangeRate(BigDecimal.ONE);
        var line=new com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine();line.setGoodsId(f.world().goodsE());line.setUnitId(f.world().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));line.setPrice(decimal("SELECT price FROM subcontract_order_items WHERE id=?",f.item()));line.setOrderItemId(f.item());r.setItems(List.of(line));return subcontractReceipts.create(r).getId();
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
