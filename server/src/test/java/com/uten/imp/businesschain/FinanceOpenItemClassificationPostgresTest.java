package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.finance.report.*;
import com.uten.imp.features.finance.statement.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.*;
import org.springframework.transaction.support.TransactionTemplate;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import static com.uten.imp.features.finance.statement.FinanceOpenItemClassificationContracts.*;
import static org.assertj.core.api.Assertions.*;

/** Full migrations over anonymous approved source facts; this does not claim the separate receipt-confirmation lifecycle. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class FinanceOpenItemClassificationPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired FinanceOpenItemClassificationService classifications;
    @Autowired FinanceClassificationCorrectionService corrections;
    @Autowired FinanceReportService reports;
    @Autowired ArApLedgerService arap;
    @Autowired JdbcTemplate db;
    @Autowired TransactionTemplate transactions;
    @Autowired com.uten.imp.features.purchase.order.PurchaseOrderService orders;
    @Autowired com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService procurementFinance;
    @Autowired com.uten.imp.features.purchase.receipt.PurchaseReceiptService receipts;
    @Autowired com.uten.imp.features.purchase.ret.PurchaseReturnService returns;
    @Autowired com.uten.imp.features.warehouse.inbound.ProcurementInspectionService inspections;
    @Autowired com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService stockIn;
    @Autowired com.uten.imp.features.finance.payment.FinancePaymentService payments;
    @Autowired com.uten.imp.features.finance.payables.SupplierOpenItemOffsetService offsets;
    private final LocalDate statementStart=com.uten.imp.common.time.BusinessTime.today().withDayOfMonth(1);
    private String sourceDate(String old){return old.equals("2026-08-31")?statementStart.minusDays(1).toString():old.startsWith("2026-09")?statementStart.toString():old;}
    private FullChainEndToEndTest fixture;private UUID financeReviewer,paymentReviewer,firstReceipt,firstOrderItem,bankAccount;
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void goodsToolingAndRealPaymentAndBothOffsetEndsConserveIndependentlyAcrossDatesAndReversals(){
        fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);var world=fixture.seedWorld("finance-classify");fixture.loginAs(world.superAdminUserId());fixture.seedChartOfAccounts();
        financeReviewer=fixture.createApprover(world);
        paymentReviewer=fixture.createUserWithPerms(world,"finance-classify-pay-reviewer","finance_payment:view","finance_payment:approve","finance_payment:reverse","finance:view:all");fixture.grantDataScope(paymentReviewer,"finance",world.employeeId());
        UUID currency=UUID.randomUUID();db.update("INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES(?,?,'匿名外币',7,'使用')",currency,"CLASS-"+currency);
        UUID opening=post(world,currency,"PURCHASE_RECEIPT","100","700","2026-08-31");
        UUID current=post(world,currency,"PURCHASE_RECEIPT","50","350","2026-09-05");
        UUID credit=post(world,currency,"PURCHASE_RETURN","-10","-70","2026-09-06");
        String supplierCode=db.queryForObject("SELECT code FROM suppliers WHERE id=?",String.class,world.supplierId());
        var pending=report(supplierCode,"2026-09-15");assertThat(pending.get("goodsAmount")).isNull();assertThat(pending.get("__pending")).isEqualTo(true);decimal(pending,"totalBalance","980");
        var openingInput=new SourceInput(UUID.randomUUID(),-1,null,"匿名原应付项目拆分",List.of(part("GOODS","60","420"),part("MOULD","40","280")));
        var opened=classifications.classifySource(opening,openingInput);assertThat(classifications.classifySource(opening,openingInput)).isEqualTo(opened);
        var currentClass=classifications.classifySource(current,new SourceInput(UUID.randomUUID(),-1,null,"匿名当期来源",List.of(part("GOODS","35","245"),part("MOULD","15","105"))));
        var creditClass=classifications.classifySource(credit,new SourceInput(UUID.randomUUID(),-1,null,"匿名退货来源",List.of(part("GOODS","-10","-70"))));
        UUID paymentLine=payment(world,currency,opening,"30","216","210","2026-09-08");
        UUID payment=db.queryForObject("SELECT payment_id FROM finance_payment_lines WHERE id=?",UUID.class,paymentLine);
        var wrong=new PaymentInput(UUID.randomUUID(),-1,opened.batchId(),"错误不能补尾差",List.of(new PaymentPart("GOODS",money("20"),money("145"),money("140")),new PaymentPart("MOULD",money("10"),money("72"),money("70"))));
        assertThatThrownBy(()->classifications.classifyPayment(paymentLine,wrong)).isInstanceOf(ApiException.class).hasMessageContaining("实际付款本币");
        assertThat(db.queryForObject("SELECT count(*) FROM finance_payment_classification_batches WHERE payment_line_id=?",Integer.class,paymentLine)).isZero();
        var paymentInput=new PaymentInput(UUID.randomUUID(),-1,opened.batchId(),"匿名原付款行分配",List.of(new PaymentPart("GOODS",money("20"),money("144"),money("140")),new PaymentPart("MOULD",money("10"),money("72"),money("70"))));
        var paid=classifications.classifyPayment(paymentLine,paymentInput);assertThat(classifications.classifyPayment(paymentLine,paymentInput)).isEqualTo(paid);
        UUID offset=offset(world,currency,credit,opening,"2026-09-10");
        var offsetInput=new OffsetInput(UUID.randomUUID(),-1,creditClass.batchId(),opened.batchId(),"明确货款贷项抵模具应付",List.of(new OffsetPart("GOODS","MOULD",money("10"),money("70"),money("70"))));
        var offsetApplied=classifications.classifyOffset(offset,offsetInput);assertThat(classifications.classifyOffset(offset,offsetInput)).isEqualTo(offsetApplied);
        var row=report(supplierCode,"2026-09-15");assertThat(row.get("__pending")).isEqualTo(false);
        decimal(row,"prevBalance","700");decimal(row,"goodsAmount","245");decimal(row,"goodsPaidAmount","144");decimal(row,"returnAmount","-70");decimal(row,"goodsOffsetAmount","-70");decimal(row,"goodsBalance","525");
        decimal(row,"mouldAmount","105");decimal(row,"mouldPaidAmount","72");decimal(row,"mouldOffsetAmount","70");decimal(row,"mouldBalance","245");decimal(row,"totalBalance","770");
        decimal(row,"__goodsCashBookDelta","4");decimal(row,"__mouldCashBookDelta","2");decimal(row,"__classificationDifference","0");
        var filtered=reports.arApSummaryTemplate("AP",statementStart,statementStart,supplierCode,1,1,new FinanceReportColumnOptions(Map.of("search.goodsBalance","525"),null,null));
        assertThat(filtered.total()).isEqualTo(1);assertThat(filtered.columns()).hasSize(15);
        assertThatThrownBy(()->classifications.classifySource(opening,new SourceInput(UUID.randomUUID(),0,null,"禁止独立改变已引用分类",List.of(part("GOODS","100","700"))))).isInstanceOf(ApiException.class).hasMessageContaining("引用");
        UUID secondLine=payment(world,currency,opening,"30","216","210","2026-09-12");
        assertThatThrownBy(()->classifications.classifyPayment(secondLine,new PaymentInput(UUID.randomUUID(),-1,opened.batchId(),"整笔误归模具",List.of(new PaymentPart("MOULD",money("30"),money("216"),money("210")))))).isInstanceOf(ApiException.class).hasMessageContaining("超过");
        assertThat(db.queryForObject("SELECT count(*) FROM finance_payment_classification_batches WHERE payment_line_id=?",Integer.class,secondLine)).isZero();
        classifications.classifyPayment(secondLine,new PaymentInput(UUID.randomUUID(),-1,opened.batchId(),"剩余明确分配",List.of(new PaymentPart("GOODS",money("10"),money("72"),money("70")),new PaymentPart("MOULD",money("20"),money("144"),money("140")))));
        UUID secondPayment=db.queryForObject("SELECT payment_id FROM finance_payment_lines WHERE id=?",UUID.class,secondLine);
        String allFacts=financialFacts(opening,current,credit,bankAccount);var complete=corrections.graph(List.of(opening,current,credit));var changed=swapGraph(complete);var correction=corrections.submit(changed);assertThat(financialFacts(opening,current,credit,bankAccount)).isEqualTo(allFacts);assertThat(classifications.classifyPayment(paymentLine,paymentInput)).isEqualTo(paid);assertThat(classifications.classifyOffset(offset,offsetInput)).isEqualTo(offsetApplied);
        corrections.submit(swapGraph(corrections.graph(List.of(opening,current,credit))));assertThat(corrections.submit(changed)).isEqualTo(correction);assertThat(financialFacts(opening,current,credit,bankAccount)).isEqualTo(allFacts);

        String currentEnd=com.uten.imp.common.time.BusinessTime.today().withDayOfMonth(com.uten.imp.common.time.BusinessTime.today().lengthOfMonth()).toString();
        UUID offsetBatch=db.queryForObject("SELECT offset_batch_id FROM supplier_open_item_offsets WHERE id=?",UUID.class,offset);
        fixture.loginAs(paymentReviewer);
        var blocked=payments.unapprovalEligibility(payment);assertThat(blocked.eligible()).isFalse();assertThat(blocked.reasons()).anySatisfy(reason->assertThat(reason.message()).contains("后抵销"));
        BigDecimal bankBefore=db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",BigDecimal.class,bankAccount);
        int vouchersBefore=db.queryForObject("SELECT count(*) FROM gl_vouchers WHERE source_doc_id=?",Integer.class,payment);
        assertThatThrownBy(()->payments.reverse(payment)).isInstanceOf(ApiException.class).hasMessageContaining("后抵销");
        assertThat(db.queryForObject("SELECT status FROM finance_payments WHERE id=?",Integer.class,payment)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",BigDecimal.class,bankAccount)).isEqualByComparingTo(bankBefore);
        assertThat(db.queryForObject("SELECT count(*) FROM gl_vouchers WHERE source_doc_id=?",Integer.class,payment)).isEqualTo(vouchersBefore);
        fixture.loginAs(world.superAdminUserId());assertThatThrownBy(()->transactions.executeWithoutResult(status->offsets.reverseBatch(offsetBatch,"错误顺序"))).isInstanceOf(ApiException.class).hasMessageContaining("后付款");
        fixture.loginAs(paymentReviewer);payments.reverse(secondPayment);fixture.loginAs(world.superAdminUserId());
        if(com.uten.imp.common.time.BusinessTime.today().isAfter(statementStart))decimal(report(supplierCode,"2026-09-15"),"totalBalance","560");decimal(report(supplierCode,currentEnd),"totalBalance","770");
        transactions.executeWithoutResult(status->offsets.reverseBatch(offsetBatch,"匿名原抵销反向"));
        decimal(report(supplierCode,currentEnd),"goodsBalance","455");decimal(report(supplierCode,currentEnd),"mouldBalance","315");
        fixture.loginAs(paymentReviewer);payments.reverse(payment);fixture.loginAs(world.superAdminUserId());
        var after=report(supplierCode,currentEnd);decimal(after,"goodsBalance","595");decimal(after,"mouldBalance","385");decimal(after,"totalBalance","980");
        UUID currentReceipt=db.queryForObject("SELECT source_doc_id FROM ar_ap_ledger WHERE id=?",UUID.class,current);
        assertThatThrownBy(()->receipts.reverse(currentReceipt)).isInstanceOf(ApiException.class).hasMessageContaining("原入库之后");
        UUID returned=db.queryForObject("SELECT source_doc_id FROM ar_ap_ledger WHERE id=?",UUID.class,credit);returns.reverse(returned);receipts.reverse(currentReceipt);
        decimal(report(supplierCode,currentEnd),"goodsAmount","0");decimal(report(supplierCode,currentEnd),"mouldAmount","0");decimal(report(supplierCode,currentEnd),"returnAmount","0");decimal(report(supplierCode,currentEnd),"totalBalance","700");
        assertThat(currentClass.revision()).isZero();
    }

    @SuppressWarnings("unchecked") private FinanceClassificationCorrectionService.Command swapGraph(Map<String,Object> graph){var nodes=new ArrayList<FinanceClassificationCorrectionService.Node>();for(var row:(List<Map<String,Object>>)graph.get("nodes")){var parts=new ArrayList<Map<String,String>>();for(var original:(List<Map<String,Object>>)row.get("parts")){var part=new LinkedHashMap<String,String>();original.forEach((k,v)->part.put(k,v.toString()));for(String key:List.of("category","sourceCategory","targetCategory")){String old=part.get(key);if("GOODS".equals(old))part.put(key,"MOULD");else if("MOULD".equals(old))part.put(key,"GOODS");}parts.add(part);}nodes.add(new FinanceClassificationCorrectionService.Node(row.get("kind").toString(),(UUID)row.get("objectId"),(UUID)row.get("expectedBatchId"),((Number)row.get("expectedRevision")).longValue(),parts));}return new FinanceClassificationCorrectionService.Command(UUID.randomUUID(),(List<UUID>)graph.get("ledgerIds"),graph.get("graphFingerprint").toString(),"正应付、实际退货贷项、两端抵销及全部已付款共同更正",nodes);}
    private String financialFacts(UUID a,UUID b,UUID c,UUID bank){return db.queryForObject("SELECT jsonb_build_object('ledgers',(SELECT jsonb_agg(to_jsonb(l)ORDER BY id)FROM ar_ap_ledger l WHERE id IN(?,?,?)),'bank',(SELECT to_jsonb(a)FROM accounts a WHERE id=?),'payments',(SELECT jsonb_agg(to_jsonb(p)ORDER BY id)FROM finance_payments p),'lines',(SELECT jsonb_agg(to_jsonb(l)ORDER BY id)FROM finance_payment_lines l),'offsets',(SELECT jsonb_agg(to_jsonb(o)ORDER BY id)FROM supplier_open_item_offsets o),'gl',(SELECT jsonb_agg(to_jsonb(e)ORDER BY id)FROM gl_entries e),'stock',(SELECT jsonb_agg(to_jsonb(m)ORDER BY id)FROM stock_movements m))::text",String.class,a,b,c,bank);}
    private UUID post(FullChainEndToEndTest.World world,UUID currency,String type,String original,String local,String date) {
        fixture.loginAs(world.superAdminUserId());UUID source;
        UUID terms=db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class);
        if(type.equals("PURCHASE_RETURN")) {
            var request=new com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest();request.setBillDate(LocalDate.parse(sourceDate(date)));request.setSupplierId(world.supplierId());request.setWarehouseId(world.warehouseId());request.setCurrencyId(currency);request.setExchangeRate(money("7"));request.setTaxRate(BigDecimal.ZERO);request.setSettlementMethodId(terms);
            var line=new com.uten.imp.features.purchase.ret.dto.ReturnItemLine();line.setGoodsId(world.goodsA());line.setUnitId(world.unitId());line.setUnitRate(BigDecimal.ONE);line.setReceiptItemId(db.queryForObject("SELECT id FROM purchase_receipt_items WHERE receipt_id=? AND NOT is_deleted",UUID.class,firstReceipt));line.setOrderItemId(firstOrderItem);line.setQty(money(original).abs().divide(money("50")));line.setPrice(money("50"));request.setItems(List.of(line));source=returns.create(request).getId();returns.approve(source);
        } else {
            BigDecimal qty=money(original).divide(money("50"));
            var order=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();order.setBillDate(LocalDate.parse(sourceDate(date)).minusDays(1));order.setSupplierId(world.supplierId());order.setWarehouseId(world.warehouseId());order.setCurrencyId(currency);order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);order.setSettlementMethodId(terms);
            var ordered=new com.uten.imp.features.purchase.order.dto.OrderItemLine();ordered.setGoodsId(world.goodsA());ordered.setUnitId(world.unitId());ordered.setUnitRate(BigDecimal.ONE);ordered.setQty(qty);ordered.setPrice(money("50"));order.setItems(List.of(ordered));UUID orderId=orders.create(order).getId();procurementFinance.submit("PURCHASE",orderId);fixture.loginAs(financeReviewer);fixture.approvePendingFinance("PURCHASE",orderId,money("7"));fixture.loginAs(world.superAdminUserId());
            UUID orderItem=db.queryForObject("SELECT id FROM purchase_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,orderId);
            var receipt=new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();receipt.setBillDate(LocalDate.parse(sourceDate(date)));receipt.setSupplierId(world.supplierId());receipt.setWarehouseId(world.warehouseId());receipt.setCurrencyId(currency);receipt.setExchangeRate(money("7"));receipt.setTaxRate(BigDecimal.ZERO);receipt.setSettlementMethodId(terms);
            var line=new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();line.setOrderItemId(orderItem);line.setGoodsId(world.goodsA());line.setUnitId(world.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(qty);line.setPrice(money("50"));receipt.setItems(List.of(line));source=receipts.create(receipt).getId();receipts.approve(source);
            UUID inspection=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='PURCHASE' AND receipt_id=?",UUID.class,source);
            inspections.dispose("PURCHASE",source,inspection,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest("PASS",null,"匿名原收货全部合格","class-pass-"+source));
            UUID event=db.queryForObject("SELECT id FROM procurement_inspection_events WHERE inspection_item_id=? AND action='PASS'",UUID.class,inspection);
            UUID keeper=fixture.createIqcWarehouseConfirmer(world,"class-stock-"+source);fixture.loginAs(keeper);
            stockIn.confirm("PURCHASE",source,new com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest("class-stock-"+source,List.of(new com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmItem(event,qty,qty,"CLASS-A01",world.warehouseId()))));fixture.loginAs(world.superAdminUserId());
            if(firstReceipt==null){firstReceipt=source;firstOrderItem=orderItem;}
        }
        UUID ledger=db.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_id=? AND source_doc_type=? AND NOT is_deleted",UUID.class,source,type);
        assertThat(db.queryForObject("SELECT amount_original_local FROM ar_ap_ledger WHERE id=?",BigDecimal.class,ledger)).isEqualByComparingTo(local);return ledger;
    }
    private UUID payment(FullChainEndToEndTest.World world,UUID currency,UUID ledger,String original,String cash,String book,String date) {
        fixture.loginAs(world.superAdminUserId());
        if(bankAccount==null){UUID style=UUID.randomUUID();db.update("INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,?,'匿名银行科目','ACCOUNT',0,'使用')",style,"CLASS-BANK-"+style);bankAccount=UUID.randomUUID();db.update("INSERT INTO accounts(id,code,name,account_type,currency_id,status,style_id,init_balance,balance_current) VALUES(?,?,'匿名外币银行','BANK',?,'使用',?,1000,1000)",bankAccount,"CLASS-BANK-"+bankAccount,currency,style);
            if(db.queryForObject("SELECT system_posting_style_id('FX_GAIN_LOSS') IS NULL",Boolean.class)){UUID fx=UUID.randomUUID();db.update("INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,?,'匿名汇兑损益','EXPENSE',0,'使用')",fx,"CLASS-FX-"+fx);db.update("UPDATE system_posting_style_roles SET style_id=? WHERE role_key='FX_GAIN_LOSS'",fx);}}
        var request=new com.uten.imp.features.finance.payment.dto.FinancePaymentSaveRequest();request.setBillDate(LocalDate.parse(sourceDate(date)));request.setSupplierId(world.supplierId());request.setAccountId(bankAccount);request.setCurrencyId(currency);request.setExchangeRate(money("7.2"));request.setAmountOriginal(money(original));request.setAccountCurrencyId(currency);request.setAccountAmount(money(original));request.setBankFeeAccountAmount(BigDecimal.ZERO);request.setBankReference("CLASS-BANK-"+UUID.randomUUID());request.setBankBookedAt(LocalDate.parse(sourceDate(date)).atTime(12,0).atOffset(java.time.ZoneOffset.ofHours(8)));request.setCreateIdempotencyKey("class-pay-"+UUID.randomUUID());
        var input=new com.uten.imp.features.finance.payment.dto.FinancePaymentLineInput();input.setAppliedLedgerId(ledger);input.setSupplierId(world.supplierId());input.setAmountOriginal(money(original));request.setItems(List.of(input));UUID payment=payments.create(request).getId();fixture.loginAs(paymentReviewer);payments.approve(payment);fixture.loginAs(world.superAdminUserId());
        UUID line=db.queryForObject("SELECT id FROM finance_payment_lines WHERE payment_id=?",UUID.class,payment);assertThat(db.queryForObject("SELECT amount_local FROM finance_payment_lines WHERE id=?",BigDecimal.class,line)).isEqualByComparingTo(cash);assertThat(db.queryForObject("SELECT applied_amount_local FROM finance_payment_lines WHERE id=?",BigDecimal.class,line)).isEqualByComparingTo(book);return line;
    }
    private UUID offset(FullChainEndToEndTest.World world,UUID currency,UUID source,UUID target,String date) {
        UUID batch=UUID.randomUUID();transactions.executeWithoutResult(status->offsets.applyBatch(batch,null,source,world.supplierId(),currency,LocalDate.parse(sourceDate(date)),List.of(new com.uten.imp.features.finance.payables.SupplierOpenItemOffsetService.Target(target,money("10"))),"匿名真实抵销"));return db.queryForObject("SELECT id FROM supplier_open_item_offsets WHERE offset_batch_id=?",UUID.class,batch);
    }
    private Map<String,Object> report(String keyword,String to){var result=reports.arApSummaryTemplate("AP",statementStart,LocalDate.parse(sourceDate(to)),keyword,1,50,FinanceReportColumnOptions.NONE);assertThat(result.rows()).hasSize(1);return result.rows().getFirst();}
    private static Part part(String category,String original,String local){return new Part(category,money(original),money(local));}
    private static BigDecimal money(String value){return new BigDecimal(value);}
    private static void decimal(Map<String,Object> row,String key,String expected){assertThat(row.get(key)).as(key).isNotNull();assertThat(new BigDecimal(row.get(key).toString())).as(key).isEqualByComparingTo(expected);}
}
