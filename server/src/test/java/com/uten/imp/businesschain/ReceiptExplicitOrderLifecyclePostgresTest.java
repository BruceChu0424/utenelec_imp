package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.application.port.ShipmentReceivablePositionPort;
import com.uten.imp.features.finance.receipt.FinanceReceiptService;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptDetail;
import com.uten.imp.features.finance.receivables.CustomerPrepaymentOffsetService;
import com.uten.imp.features.finance.receivables.CustomerPrepaymentContracts;
import com.uten.imp.features.finance.receivables.CustomerPrepaymentQueryService;
import com.uten.imp.businesschain.ShipmentReceivableBatchFixture.Prepared;
import com.uten.imp.businesschain.ShipmentReceivableBatchFixture.PreparedSingle;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;

/** Real stock, approved orders and shipments; cash and actually applied advances settle only the selected shipment AR. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ReceiptExplicitOrderLifecyclePostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired FinanceReceiptService receipts;
    @Autowired CustomerPrepaymentQueryService summaries;
    @Autowired ShipmentReceivablePositionPort shipmentPositions;
    @Autowired CustomerPrepaymentOffsetService offsets;
    @Autowired PlatformTransactionManager transactions;
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void shipmentBatchCompanyFeeKeepsGrossSettlementAndRejectsUnrelatedOrderSource(){
        Prepared batch=prepareBatch("batch-company-fee");
        var fixture=batch.fixture();var world=batch.world();
        UUID firstOrder=batch.firstOrder(),secondOrder=batch.secondOrder(),ledger=batch.ledger(),bank=batch.bank(),reviewer=batch.reviewer();
        assertSummary(firstOrder,"0","0","1000","7000","2000");
        assertSummary(secondOrder,"0","0","0","0","1000");
        assertBatch(batch,"0","0","1000");

        // Customer settlement is 200; bank receives 190 and retains a 10 fee.
        // AR was recognized at 7; the actual bank settlement is 7.2.
        var request=actualReceipt(batch,"200","190","10");
        request.getItems().getFirst().setRequestedSalesOrderId(firstOrder);
        var draft=receipts.create(request);UUID receipt=draft.getId();
        assertShipmentSource(draft,batch.shipment(),ledger);
        assertThat(receipts.create(request).getId()).isEqualTo(receipt);
        amount("0","SELECT balance_current FROM accounts WHERE id=?",bank);
        amount("1000","SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",ledger);
        assertThat(draft.getItems()).singleElement().satisfies(line->
                assertThat(line.getRequestedSalesOrderId()).isEqualTo(firstOrder));

        fixture.loginAs(reviewer);assertShipmentSource(receipts.approve(receipt),batch.shipment(),ledger);
        assertThatThrownBy(()->receipts.approve(receipt)).isInstanceOf(ApiException.class);
        amount("190","SELECT balance_current FROM accounts WHERE id=?",bank);
        amount("200","SELECT amount_received_original FROM ar_ap_ledger WHERE id=?",ledger);
        amount("1440","SELECT amount_received_local FROM ar_ap_ledger WHERE id=?",ledger);
        amount("1400","SELECT amount_settled FROM ar_ap_ledger WHERE id=?",ledger);
        amount("800","SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",ledger);
        amount("5600","SELECT amount_balance FROM ar_ap_ledger WHERE id=?",ledger);
        amount("190","SELECT account_amount FROM finance_receipts WHERE id=?",receipt);
        amount("1368","SELECT account_amount_local FROM finance_receipts WHERE id=?",receipt);
        amount("10","SELECT bank_fee_account_amount FROM finance_receipts WHERE id=?",receipt);
        amount("72","SELECT bank_fee FROM finance_receipts WHERE id=?",receipt);
        amount("40","SELECT exchange_diff FROM finance_receipt_lines WHERE receipt_id=?",receipt);
        assertThat(db.queryForList("SELECT sales_order_id FROM finance_receipt_source_allocations WHERE receipt_id=? AND status='APPLIED'",
                UUID.class,receipt)).containsExactly(firstOrder);
        amount("200","SELECT cash_original FROM finance_receipt_source_allocations WHERE receipt_id=? AND status='APPLIED'",receipt);
        amount("1400","SELECT applied_book_local FROM finance_receipt_source_allocations WHERE receipt_id=? AND status='APPLIED'",receipt);
        assertSummary(firstOrder,"200","1440","800","5600","1800");
        assertSummary(secondOrder,"0","0","0","0","1000");
        assertBatch(batch,"200","0","800");
        assertIntegrity(receipt);

        fixture.loginAs(world.superAdminUserId());
        assertThat(receipts.create(request).getId()).isEqualTo(receipt);
        amount("190","SELECT balance_current FROM accounts WHERE id=?",bank);
        assertThat(db.queryForObject("SELECT count(*) FROM finance_receipt_source_allocations WHERE receipt_id=?",Long.class,receipt)).isEqualTo(1L);
        request.getItems().getFirst().setRequestedSalesOrderId(secondOrder);
        assertThatThrownBy(()->receipts.create(request)).isInstanceOf(ApiException.class).hasMessageContaining("提交编号");
        request.getItems().getFirst().setRequestedSalesOrderId(firstOrder);

        // A distinct valid order for the same customer is still not a source of this batch.
        long beforeRows=db.queryForObject("SELECT count(*) FROM finance_receipts WHERE client_id=?",Long.class,world.clientId());
        var unrelated=actualReceipt(batch,"20","19","1");
        unrelated.getItems().getFirst().setRequestedSalesOrderId(secondOrder);
        assertThatThrownBy(()->receipts.create(unrelated)).isInstanceOf(ApiException.class).hasMessageContaining("来源");
        assertThat(db.queryForObject("SELECT count(*) FROM finance_receipts WHERE client_id=?",Long.class,world.clientId())).isEqualTo(beforeRows);
        amount("190","SELECT balance_current FROM accounts WHERE id=?",bank);
        amount("800","SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",ledger);

        // Shipment AR is the mandatory collection source. Order attribution is
        // optional before approval; removing it must keep the same batch and bank facts.
        var editable=actualReceipt(batch,"20","19","1");
        editable.getItems().getFirst().setRequestedSalesOrderId(firstOrder);
        var editableDraft=receipts.create(editable);
        editable.setExpectedVersion(editableDraft.getVersion());
        editable.getItems().getFirst().setRequestedSalesOrderId(null);
        var edited=receipts.update(editableDraft.getId(),editable);
        assertShipmentSource(edited,batch.shipment(),ledger);
        assertThat(edited.getItems()).singleElement().satisfies(line->{
            assertThat(line.getRequestedSalesOrderId()).isNull();
            assertThat(line.getAppliedLedgerId()).isEqualTo(ledger);
            assertThat(line.getAmountOriginal()).isEqualByComparingTo("20");
        });
        receipts.delete(editableDraft.getId());
        amount("190","SELECT balance_current FROM accounts WHERE id=?",bank);

        fixture.loginAs(reviewer);receipts.reverse(receipt);
        assertShipmentSource(receipts.detail(receipt),batch.shipment(),ledger);
        amount("0","SELECT balance_current FROM accounts WHERE id=?",bank);
        amount("1000","SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",ledger);
        amount("7000","SELECT amount_balance FROM ar_ap_ledger WHERE id=?",ledger);
        amount("0","SELECT amount_received_original FROM ar_ap_ledger WHERE id=?",ledger);
        amount("0","SELECT amount_received_local FROM ar_ap_ledger WHERE id=?",ledger);
        amount("0","SELECT amount_settled FROM ar_ap_ledger WHERE id=?",ledger);
        assertThat(db.queryForList("SELECT sales_order_id FROM finance_receipt_source_allocations WHERE receipt_id=? AND status='REVERSED'",
                UUID.class,receipt)).containsExactly(firstOrder);
        assertSummary(firstOrder,"0","0","1000","7000","2000");
        assertSummary(secondOrder,"0","0","0","0","1000");
        assertBatch(batch,"0","0","1000");
        assertIntegrity(receipt);
        fixture.loginAs(world.superAdminUserId());
        assertThat(receipts.create(request).getId()).isEqualTo(receipt);
        amount("0","SELECT balance_current FROM accounts WHERE id=?",bank);
        assertThat(db.queryForObject("SELECT count(*) FROM finance_reconciliations WHERE source_doc_type='RECEIPT' AND source_doc_id=?",
                Long.class,receipt)).isEqualTo(2L);
    }

    @Test void shipmentBatchPartial400Then600ReplaysAndReversesExactBalance(){
        Prepared batch=prepareBatch("batch-partial-cash");
        var fixture=batch.fixture();var world=batch.world();
        assertBatch(batch,"0","0","1000");
        assertOpenMembership(batch,true);
        var firstRequest=actualReceipt(batch,"400","400","0");
        assertThat(firstRequest.getItems().getFirst().getRequestedSalesOrderId()).isNull();
        var firstDraft=receipts.create(firstRequest);UUID first=firstDraft.getId();
        assertShipmentSource(firstDraft,batch.shipment(),batch.ledger());
        assertThat(receipts.create(firstRequest).getId()).isEqualTo(first);
        assertBatch(batch,"0","0","1000");
        fixture.loginAs(batch.reviewer());assertShipmentSource(receipts.approve(first),batch.shipment(),batch.ledger());
        assertBatch(batch,"400","0","600");
        assertOpenMembership(batch,true);
        amount("400","SELECT balance_current FROM accounts WHERE id=?",batch.bank());
        assertThat(db.queryForObject("SELECT warehouse_work_status FROM sales_shipments WHERE id=?",String.class,batch.shipment())).isEqualTo("SHIPPED");
        // Shipped goods, a credit due date and an agreed arrival-based tail payment
        // do not create cash. Repeated follow-up reads must still show this batch's 600.
        assertBatch(batch,"400","0","600");
        fixture.loginAs(world.superAdminUserId());
        assertThat(receipts.create(firstRequest).getId()).isEqualTo(first);
        amount("400","SELECT balance_current FROM accounts WHERE id=?",batch.bank());

        var lastRequest=actualReceipt(batch,"600","600","0");
        var lastDraft=receipts.create(lastRequest);UUID last=lastDraft.getId();
        assertShipmentSource(lastDraft,batch.shipment(),batch.ledger());
        fixture.loginAs(batch.reviewer());assertShipmentSource(receipts.approve(last),batch.shipment(),batch.ledger());
        assertBatch(batch,"1000","0","0");
        assertOpenMembership(batch,false);
        amount("1000","SELECT balance_current FROM accounts WHERE id=?",batch.bank());
        assertThatThrownBy(()->receipts.reverse(first)).isInstanceOf(ApiException.class);
        assertBatch(batch,"1000","0","0");
        receipts.reverse(last);
        assertBatch(batch,"400","0","600");
        assertOpenMembership(batch,true);
        amount("400","SELECT balance_current FROM accounts WHERE id=?",batch.bank());
        receipts.reverse(first);
        assertBatch(batch,"0","0","1000");
        assertOpenMembership(batch,true);
        assertShipmentSource(receipts.detail(first),batch.shipment(),batch.ledger());
        amount("0","SELECT balance_current FROM accounts WHERE id=?",batch.bank());
        amount("7000","SELECT amount_balance FROM ar_ap_ledger WHERE id=?",batch.ledger());
        assertIntegrity(first);assertIntegrity(last);
        fixture.loginAs(world.superAdminUserId());
        assertThat(receipts.create(firstRequest).getId()).isEqualTo(first);
        assertThat(receipts.create(lastRequest).getId()).isEqualTo(last);
        assertBatch(batch,"0","0","1000");
        amount("0","SELECT balance_current FROM accounts WHERE id=?",batch.bank());
        assertThat(db.queryForObject("SELECT count(*) FROM finance_reconciliations WHERE source_doc_type='RECEIPT' AND source_doc_id IN(?,?)",
                Long.class,first,last)).isEqualTo(4L);
    }

    @Test void orderBoundPrepaymentChangesThisBatchOnlyAfterActualOffset(){
        Prepared batch=prepareBatch("batch-advance-cash");
        var fixture=batch.fixture();var world=batch.world();
        // The same main order has a second real physical shipment. A target offset
        // must not pay this sibling batch merely because customer/order identities match.
        Prepared siblingBatch=ShipmentReceivableBatchFixture.shipNext(beans,db,batch);
        UUID sibling=siblingBatch.shipment(),siblingLedger=siblingBatch.ledger();
        assertBatch(batch,"0","0","1000");
        assertPosition(sibling,siblingLedger,world.currencyId(),"0","0","1000");
        var advance=actualReceipt(batch,"300","300","0");
        advance.setReceiptKind("CUSTOMER_PREPAYMENT");advance.setSalesOrderId(batch.firstOrder());
        advance.setCurrencyId(world.currencyId());advance.setExchangeRate(n("7.2"));
        advance.setAmountOriginal(n("300"));advance.setItems(List.of());
        UUID advanceReceipt=receipts.create(advance).getId();
        fixture.loginAs(batch.reviewer());receipts.approve(advanceReceipt);
        fixture.loginAs(world.superAdminUserId());
        UUID advanceLedger=db.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_type='DIRECT_RECEIPT' AND source_doc_id=?",UUID.class,advanceReceipt);
        amount("300","SELECT balance_current FROM accounts WHERE id=?",batch.bank());
        assertThat(n(summaries.salesOrderSummary(batch.firstOrder()).prepaymentAvailableOriginal())).isEqualByComparingTo("300");
        assertBatch(batch,"0","0","1000");
        assertPosition(sibling,siblingLedger,world.currencyId(),"0","0","1000");

        var apply=new CustomerPrepaymentContracts.ApplyRequest("actual-batch-advance-"+advanceReceipt,advanceLedger,
                List.of(new CustomerPrepaymentContracts.Target(batch.ledger(),batch.firstOrder(),n("200"))),"真实订单定金只抵本批发货应收200");
        var applied=offsets.apply(apply);
        assertThat(offsets.apply(apply).batchId()).isEqualTo(applied.batchId());
        assertBatch(batch,"0","200","800");
        assertPosition(sibling,siblingLedger,world.currencyId(),"0","0","1000");
        amount("300","SELECT balance_current FROM accounts WHERE id=?",batch.bank());
        amount("800","SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",batch.ledger());
        amount("100","SELECT ABS(amount_balance_original) FROM ar_ap_ledger WHERE id=?",advanceLedger);
        offsets.reverse(applied.batchId(),new CustomerPrepaymentContracts.ReverseRequest(applied.rowVersion(),"撤回本批实际定金抵扣"));
        assertBatch(batch,"0","0","1000");
        assertPosition(sibling,siblingLedger,world.currencyId(),"0","0","1000");
        fixture.loginAs(batch.reviewer());receipts.reverse(advanceReceipt);
        fixture.loginAs(world.superAdminUserId());
        amount("0","SELECT balance_current FROM accounts WHERE id=?",batch.bank());
        assertBatch(batch,"0","0","1000");
        assertPosition(sibling,siblingLedger,world.currencyId(),"0","0","1000");
        assertIntegrity(advanceReceipt);
    }

    @Test void closedFulfilledOrder735CanRetainActualPrepayment1000AndUnapplied265(){
        PreparedSingle batch=ShipmentReceivableBatchFixture.prepareSingle(beans,db,"closed-batch-overpay");
        var fixture=batch.fixture();var world=batch.world();
        assertThat(db.queryForObject("SELECT is_closed FROM sales_orders WHERE id=?",Boolean.class,batch.order())).isTrue();
        amount("7","SELECT shipped_qty FROM sales_order_items WHERE id=?",batch.item());
        amount("0","SELECT reserved_qty FROM sales_order_items WHERE id=?",batch.item());
        assertPosition(batch.shipment(),batch.ledger(),world.currencyId(),"735","0","0","735");
        assertOpenMembership(fixture,world,batch.shipment(),true);
        var request=actualReceipt(fixture,world,batch.ledger(),batch.bank(),"1000","1000","0");
        request.setReceiptKind("CUSTOMER_PREPAYMENT");request.setSalesOrderId(batch.order());
        request.setCurrencyId(world.currencyId());request.setExchangeRate(n("7.2"));
        request.setAmountOriginal(n("1000"));request.setItems(List.of());
        var draft=receipts.create(request);UUID receipt=draft.getId();
        assertThat(draft.getSalesOrderId()).isEqualTo(batch.order());
        assertThat(receipts.create(request).getId()).isEqualTo(receipt);
        fixture.loginAs(batch.reviewer());receipts.approve(receipt);
        fixture.loginAs(world.superAdminUserId());
        UUID advanceLedger=db.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_type='DIRECT_RECEIPT' AND source_doc_id=?",UUID.class,receipt);
        amount("1000","SELECT balance_current FROM accounts WHERE id=?",batch.bank());
        assertThat(n(summaries.salesOrderSummary(batch.order()).prepaymentAvailableOriginal())).isEqualByComparingTo("1000");
        // The whole real receipt is still an order advance until a specific batch is actually offset.
        assertPosition(batch.shipment(),batch.ledger(),world.currencyId(),"735","0","0","735");
        var apply=new CustomerPrepaymentContracts.ApplyRequest("closed-batch-advance-"+receipt,advanceLedger,
                List.of(new CustomerPrepaymentContracts.Target(batch.ledger(),batch.order(),n("735"))),"实际预收1000仅抵本批735，余额265保留本订单预收");
        var applied=offsets.apply(apply);
        assertThat(offsets.apply(apply).batchId()).isEqualTo(applied.batchId());
        assertPosition(batch.shipment(),batch.ledger(),world.currencyId(),"735","0","735","0");
        assertOpenMembership(fixture,world,batch.shipment(),false);
        amount("265","SELECT ABS(amount_balance_original) FROM ar_ap_ledger WHERE id=?",advanceLedger);
        amount("1908","SELECT ABS(amount_balance) FROM ar_ap_ledger WHERE id=?",advanceLedger);
        amount("0","SELECT amount_original FROM ar_ap_ledger WHERE id=?",advanceLedger);
        assertThat(db.queryForObject("SELECT open_item_kind FROM ar_ap_ledger WHERE id=?",String.class,advanceLedger)).isEqualTo("CUSTOMER_PREPAYMENT");
        assertThat(n(summaries.salesOrderSummary(batch.order()).prepaymentAvailableOriginal())).isEqualByComparingTo("265");
        assertThat(db.queryForList("SELECT target_ledger_id FROM customer_open_item_offsets WHERE source_ledger_id=? AND status='APPLIED'",UUID.class,advanceLedger)).containsExactly(batch.ledger());
        amount("1000","SELECT balance_current FROM accounts WHERE id=?",batch.bank());
        assertThat(db.queryForObject("SELECT is_closed FROM sales_orders WHERE id=?",Boolean.class,batch.order())).isTrue();
        amount("7","SELECT shipped_qty FROM sales_order_items WHERE id=?",batch.item());
        amount("0","SELECT reserved_qty FROM sales_order_items WHERE id=?",batch.item());
        offsets.reverse(applied.batchId(),new CustomerPrepaymentContracts.ReverseRequest(applied.rowVersion(),"撤回本批735实际预收核销"));
        assertPosition(batch.shipment(),batch.ledger(),world.currencyId(),"735","0","0","735");
        assertOpenMembership(fixture,world,batch.shipment(),true);
        assertThat(n(summaries.salesOrderSummary(batch.order()).prepaymentAvailableOriginal())).isEqualByComparingTo("1000");
        fixture.loginAs(batch.reviewer());receipts.reverse(receipt);fixture.loginAs(world.superAdminUserId());
        amount("0","SELECT balance_current FROM accounts WHERE id=?",batch.bank());
        assertPosition(batch.shipment(),batch.ledger(),world.currencyId(),"735","0","0","735");
        assertThat(n(summaries.salesOrderSummary(batch.order()).prepaymentAvailableOriginal())).isZero();
        assertThat(db.queryForObject("SELECT is_closed FROM sales_orders WHERE id=?",Boolean.class,batch.order())).isTrue();
        amount("0","SELECT reserved_qty FROM sales_order_items WHERE id=?",batch.item());
        assertThat(receipts.create(request).getId()).isEqualTo(receipt);
        amount("0","SELECT balance_current FROM accounts WHERE id=?",batch.bank());assertIntegrity(receipt);
    }

    private FinanceReceiptSaveRequest actualReceipt(Prepared batch,String amount,String bankAmount,String fee){
        return actualReceipt(batch.fixture(),batch.world(),batch.ledger(),batch.bank(),amount,bankAmount,fee);
    }
    private FinanceReceiptSaveRequest actualReceipt(FullChainEndToEndTest fixture,FullChainEndToEndTest.World world,
                                                  UUID ledger,UUID bank,String amount,String bankAmount,String fee){
        var request=fixture.receiptRequest(world,ledger,bank,null,
                amount,bankAmount,fee,"0",n("7.2"),BusinessTime.today());
        // A declared bank fact already occurred at the start of this business day.
        // Unlike a fixed 10:00 fixture, it cannot silently become a future booking in an early run.
        var occurred=BusinessTime.today().atStartOfDay().atOffset(ZoneOffset.ofHours(8));
        request.setBankBookedAt(occurred);request.setExchangeRateEffectiveAt(occurred);
        return request;
    }

    private Prepared prepareBatch(String tag){return ShipmentReceivableBatchFixture.prepare(beans,db,tag);}
    private ShipmentReceivablePositionPort.Position position(UUID shipment){
        var read=new TransactionTemplate(transactions);read.setReadOnly(true);read.setIsolationLevel(TransactionDefinition.ISOLATION_REPEATABLE_READ);
        return read.execute(ignored->shipmentPositions.read(List.of(shipment)).get(shipment));
    }
    private void assertBatch(Prepared batch,String cash,String advance,String balance){
        assertPosition(batch.shipment(),batch.ledger(),batch.world().currencyId(),cash,advance,balance);
    }
    private void assertPosition(UUID shipment,UUID ledger,UUID currency,String cash,String advance,String balance){
        assertPosition(shipment,ledger,currency,"1000",cash,advance,balance);
    }
    private void assertPosition(UUID shipment,UUID ledger,UUID currency,String formal,String cash,String advance,String balance){
        var value=position(shipment);assertThat(value).isNotNull();assertThat(value.complete()).isTrue();
        assertThat(value.state()).isEqualTo("READY");assertThat(value.warnings()).isEmpty();
        assertThat(value.ledgerId()).isEqualTo(ledger);assertThat(value.currencyId()).isEqualTo(currency);
        assertThat(n(value.shipmentOriginal())).isEqualByComparingTo(formal);
        assertThat(n(value.formalReceivableOriginal())).isEqualByComparingTo(formal);
        assertThat(n(value.cashReceivedOriginal())).isEqualByComparingTo(cash);
        assertThat(n(value.prepaymentAppliedOriginal())).isEqualByComparingTo(advance);
        assertThat(n(value.confirmedPaidOriginal())).isEqualByComparingTo(n(cash).add(n(advance)));
        assertThat(n(value.balanceOriginal())).isEqualByComparingTo(balance);
        assertThat(n(value.reductionOriginal())).isZero();assertThat(n(value.returnOffsetOriginal())).isZero();
        assertThat(n(value.otherOffsetOriginal())).isZero();
        LocalDate recognized=db.queryForObject("SELECT bill_date FROM ar_ap_ledger WHERE id=?",LocalDate.class,ledger);
        assertThat(value.dueDate()).isEqualTo(recognized.plusDays(30).toString());
        assertThat(value.overdueDays()).isZero();
    }

    private void assertShipmentSource(FinanceReceiptDetail receipt,UUID shipment,UUID ledger){
        String no=db.queryForObject("SELECT bill_no FROM sales_shipments WHERE id=?",String.class,shipment);
        assertThat(receipt.getItems()).singleElement().satisfies(line->{
            assertThat(line.getAppliedLedgerId()).isEqualTo(ledger);
            assertThat(line.getAppliedSourceDocType()).isEqualTo("SALES_SHIPMENT");
            assertThat(line.getAppliedSourceDocId()).isEqualTo(shipment);
            assertThat(line.getAppliedSourceDocNo()).isEqualTo(no);
        });
    }
    private void assertOpenMembership(Prepared batch,boolean present){
        assertOpenMembership(batch.fixture(),batch.world(),batch.shipment(),present);
    }
    private void assertOpenMembership(FullChainEndToEndTest fixture,FullChainEndToEndTest.World world,UUID shipment,boolean present){
        var principal=SecurityContextHolder.getContext();fixture.loginAs(world.superAdminUserId());
        try{
            var page=ShipmentReceivableBatchFixture.openShipments(beans,db,shipment);
            assertThat(page.getTotal()).isEqualTo(present?1L:0L);
            if(present)assertThat(page.getItems()).singleElement().satisfies(row->assertThat(row.getId()).isEqualTo(shipment));
            else assertThat(page.getItems()).isEmpty();
        }finally{SecurityContextHolder.setContext(principal);}
    }

    private void assertSummary(UUID order,String cash,String cashLocal,String outstanding,String outstandingLocal,String planned){
        var value=summaries.salesOrderSummary(order);
        assertThat(value.positionComplete()).isTrue();assertThat(value.hasUnallocated()).isFalse();
        assertThat(n(value.cashReceivedOriginal())).isEqualByComparingTo(cash);
        assertThat(n(value.cashReceivedLocal())).isEqualByComparingTo(cashLocal);
        assertThat(n(value.arOutstandingOriginal())).isEqualByComparingTo(outstanding);
        assertThat(n(value.arOutstandingLocal())).isEqualByComparingTo(outstandingLocal);
        assertThat(n(value.plannedRemainingOriginal())).isEqualByComparingTo(planned);
    }
    private void assertIntegrity(UUID receipt){
        assertThat(db.queryForObject("SELECT is_consistent FROM v_receipt_gl_integrity WHERE receipt_id=?",Boolean.class,receipt)).isTrue();
        assertThat(db.queryForObject("SELECT is_consistent FROM v_receipt_flow_integrity WHERE receipt_id=?",Boolean.class,receipt)).isTrue();
    }
    private void amount(String expected,String sql,Object... args){assertThat(db.queryForObject(sql,BigDecimal.class,args)).isEqualByComparingTo(expected);}
    private static BigDecimal n(String text){return new BigDecimal(text);}
}
