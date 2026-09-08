package com.uten.imp.features.finance.receivables;

import com.uten.imp.features.finance.receivables.CustomerPrepaymentContracts.SalesOrderMoneySummary;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.UUID;
import java.math.BigDecimal;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Real PostgreSQL proof that the sales-order money summary executes every native
 * aggregate (aliases must avoid reserved words such as OFFSET) and stays conservative
 * on an order without any receipts, ledger rows, or prepayment offsets.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(
        webEnvironment = SpringBootTest.WebEnvironment.MOCK,
        properties = {
                "spring.profiles.active=dev",
                "uten.audit.retention.enabled=false",
                "uten.reporting.materialized-view-refresh.enabled=false",
                "uten.policy-intelligence.enabled=false",
                "uten.features.goods-owner-scope-enabled=false",
                "uten.jwt.secret=prepayment-summary-harness-jwt-secret-0123456789-test-only",
                "uten.crypto.pgp-master-key=prepayment-summary-harness-pgp-key-test-only-0123456",
                "uten.crypto.hmac-key=prepayment-summary-harness-hmac-key-test-only",
                "uten.bootstrap.admin-login=prepayment-summary-bootstrap-admin-test",
                "uten.bootstrap.admin-password=PrepaymentSummaryAdminPass-1!"
        })
class CustomerPrepaymentSummaryPostgresTest {
    private static final AtomicInteger SEQUENCE = new AtomicInteger(10);

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @DynamicPropertySource
    static void registerDataSource(DynamicPropertyRegistry registry) {
        POSTGRES.start();
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
    }

    @Autowired
    private JdbcTemplate jdbc;

    @Autowired
    private CustomerPrepaymentQueryService service;

    @Autowired
    private TransactionTemplate transactions;

    @Test
    void summaryExecutesAllAggregatesAndReportsZeroMoneyForAnOrderWithoutActivity() {
        UUID clientId = UUID.randomUUID();
        UUID currencyId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        String suffix = orderId.toString().replace("-", "").substring(0, 6).toUpperCase(java.util.Locale.ROOT);
        // fn_reserve_business_document_identifier 要求 XD+YYYYMMDD+6位流水
        String orderBillNo = "XD20260827000001";
        jdbc.update("""
                INSERT INTO clients(id,code,name,status,code_sequence,sales_payment_type)
                VALUES(?,?,?,'使用',(SELECT COALESCE(MAX(code_sequence),0)+1 FROM clients),'MONTHLY')
                """, clientId, "CP-SUM-" + suffix, "Customer prepayment summary");
        jdbc.update("""
                INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES(?,?,?,1,'使用')
                """, currencyId, "SUM-" + suffix, "Summary currency");
        jdbc.update("""
                INSERT INTO sales_orders(id,bill_no,bill_date,client_id,currency_id,exchange_rate,
                    total_original,total_local,status,is_closed,is_stopped,deposit,shipment_policy)
                VALUES(?,?,DATE '2026-08-27',?,?,1,20,20,1,FALSE,FALSE,0,'ALLOW_PARTIAL')
                """, orderId, orderBillNo, clientId, currencyId);
        UUID goods = seedGoods(suffix);
        jdbc.update("""
                INSERT INTO sales_order_items(id,order_id,bill_no,bill_date,goods_id,qty,price,
                    amount_original,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at)
                VALUES(gen_random_uuid(),?,?,DATE '2026-08-27',?,2,10,20,?,'Summary goods','MASTER_AT_APPROVAL',now())
                """, orderId, orderBillNo, goods, "SUM-G-"+suffix);

        SalesOrderMoneySummary summary = service.salesOrderSummary(orderId);

        assertThat(summary.salesOrderId()).isEqualTo(orderId);
        assertThat(summary.orderBillNo()).isEqualTo(orderBillNo);
        assertMoney(summary.orderTotalOriginal(), "20.0000");
        assertMoney(summary.formalArOriginal(), "0.0000");
        assertMoney(summary.cashReceivedOriginal(), "0.0000");
        assertMoney(summary.prepaymentAppliedOriginal(), "0.0000");
        assertMoney(summary.prepaymentAppliedTargetBookLocal(), "0.0000");
        assertMoney(summary.prepaymentExchangeDifferenceLocal(), "0.0000");
        assertMoney(summary.arOutstandingOriginal(), "0.0000");
        assertMoney(summary.plannedRemainingOriginal(), "20.0000");
        assertMoney(summary.overpaidOriginal(), "0.0000");
        assertThat(summary.hasUnallocated()).isFalse();
        assertThat(summary.unallocatedReceiptLines()).isEmpty();
        assertThat(summary.warnings()).isEmpty();
    }

    @Test
    void exchangeReturnReopensFutureShipmentsWithoutUnderstatingRemainingCollection() {
        UUID order = seedPosition("exchange", "200", "10", "5", "0", "100", "100", "50", "-50");
        var summary = service.salesOrderSummary(order);
        assertThat(summary.positionComplete()).isTrue();
        assertMoney(summary.formalArOriginal(), "100.0000");
        assertMoney(summary.returnCreditOriginal(), "50.0000");
        assertMoney(summary.netReceivableOriginal(), "50.0000");
        assertMoney(summary.unrecognizedOrderOriginal(), "150.0000");
        assertMoney(summary.plannedRemainingOriginal(), "200.0000");
    }

    @Test
    void returnWithoutReplacementClosesOnlyItsFlaggedFutureQuantity() {
        UUID order = seedPosition("closed", "200", "10", "5", "5", "100", "100", "50", "-50");
        var summary = service.salesOrderSummary(order);
        assertThat(summary.positionComplete()).isTrue();
        assertMoney(summary.netReceivableOriginal(), "50.0000");
        assertMoney(summary.unrecognizedOrderOriginal(), "100.0000");
        assertMoney(summary.plannedRemainingOriginal(), "150.0000");
    }

    @Test
    void alreadyAppliedReturnIsNotSubtractedFromInvoiceBalanceTwice() {
        UUID order = seedPosition("applied", "200", "10", "5", "0", "100", "50", "50", "0");
        var summary = service.salesOrderSummary(order);
        assertThat(summary.positionComplete()).isTrue();
        assertMoney(summary.returnCreditOriginal(), "50.0000");
        assertMoney(summary.unusedReturnCreditOriginal(), "0.0000");
        assertMoney(summary.arOutstandingOriginal(), "50.0000");
        assertMoney(summary.netReceivableOriginal(), "50.0000");
        assertMoney(summary.plannedRemainingOriginal(), "200.0000");
    }

    @Test
    void paidThenReturnedOrderShowsUnresolvedCustomerBalanceWithoutInventingARefund() {
        UUID order = seedPosition("paidreturn", "100", "10", "10", "10", "100", "0", "100", "-100");
        var summary = service.salesOrderSummary(order);
        assertThat(summary.positionComplete()).isTrue();
        assertMoney(summary.netReceivableOriginal(), "0.0000");
        assertMoney(summary.customerPendingBalanceOriginal(), "100.0000");
        assertThat(summary.hasUnallocated()).isTrue();
        assertThat(summary.cashReceivedOriginal()).isNull();
        assertMoney(summary.unrecognizedOrderOriginal(), "0.0000");
        assertMoney(summary.plannedRemainingOriginal(), "0.0000");
    }

    private UUID seedGoods(String suffix) {
        UUID id=UUID.randomUUID();
        jdbc.update("""
                INSERT INTO goods(id,code,name,status,code_sequence)
                VALUES(?,?,'Summary goods','使用',(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))
                """,id,"SUM-G-"+suffix);
        return id;
    }

    private UUID seedPosition(String name,String orderAmount,String shippedQty,String returnedQty,String flaggedQty,
                              String invoiceAmount,String invoiceBalance,String returnAmount,String returnBalance) {
        return transactions.execute(ignored -> seedPositionInTransaction(name, orderAmount, shippedQty,
                returnedQty, flaggedQty, invoiceAmount, invoiceBalance, returnAmount, returnBalance));
    }

    private UUID seedPositionInTransaction(String name,String orderAmount,String shippedQty,String returnedQty,String flaggedQty,
                                           String invoiceAmount,String invoiceBalance,String returnAmount,String returnBalance) {
        int sequence=SEQUENCE.incrementAndGet();
        String suffix=name+"-"+sequence;
        UUID client=UUID.randomUUID(),currency=UUID.randomUUID(),order=UUID.randomUUID(),orderItem=UUID.randomUUID();
        UUID shipment=UUID.randomUUID(),shipmentItem=UUID.randomUUID(),invoice=UUID.randomUUID(),returned=UUID.randomUUID();
        UUID actorUser=jdbc.queryForObject("SELECT id FROM users WHERE is_super_admin AND employee_id IS NOT NULL LIMIT 1",UUID.class);
        UUID actor=jdbc.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,actorUser);
        String orderNo="XD20260907%06d".formatted(sequence);
        String shipmentNo="XC20260907%06d".formatted(sequence);
        String returnNo="XT20260907%06d".formatted(sequence);
        UUID goods=seedGoods(suffix);
        jdbc.update("""
                INSERT INTO clients(id,code,name,status,code_sequence,sales_payment_type)
                VALUES(?,?,'Summary client','使用',(SELECT COALESCE(MAX(code_sequence),0)+1 FROM clients),'MONTHLY')
                """,client,"SUM-C-"+suffix);
        jdbc.update("INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES(?,?,?,1,'使用')",currency,"SC-"+sequence,"Summary currency");
        jdbc.update("""
                INSERT INTO sales_orders(id,bill_no,bill_date,client_id,currency_id,total_original,total_local,
                    status,finance_confirmed,finance_confirmed_at,finance_confirmed_by,shipment_policy)
                VALUES(?,?,DATE '2026-09-07',?,?,?,?,1,TRUE,now(),?,'ALLOW_PARTIAL')
                """,order,orderNo,client,currency,new BigDecimal(orderAmount),new BigDecimal(orderAmount),actor);
        jdbc.update("""
                INSERT INTO sales_order_items(id,order_id,bill_no,bill_date,goods_id,qty,price,amount_original,
                    shipped_qty,returned_qty,flag_qty,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at)
                VALUES(?,?,?,DATE '2026-09-07',?,?,10,?,?,?,?,?,'Summary goods','MASTER_AT_APPROVAL',now())
                """,orderItem,order,orderNo,goods,new BigDecimal(orderAmount).divide(BigDecimal.TEN),
                new BigDecimal(orderAmount),new BigDecimal(shippedQty),new BigDecimal(returnedQty),new BigDecimal(flaggedQty),"SUM-G-"+suffix);
        jdbc.update("""
                INSERT INTO sales_shipments(id,bill_no,bill_date,client_id,currency_id,exchange_rate,tax_rate,
                    status,warehouse_work_status,finance_gate_version,finance_audit,
                    source_order_id,ar_posted,total_original,total_local)
                VALUES(?,?,DATE '2026-09-07',?,?,1,0,0,'PENDING_PICK',2,0,?,FALSE,?,?)
                """,shipment,shipmentNo,client,currency,order,new BigDecimal(invoiceAmount),new BigDecimal(invoiceAmount));
        jdbc.update("""
                INSERT INTO sales_shipment_items(id,shipment_id,order_item_id,bill_no,bill_date,goods_id,
                    qty,price,amount_original,amount_local,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at)
                VALUES(?,?,?,?,DATE '2026-09-07',?,?,10,?, ?,?,'Summary goods','MASTER_AT_APPROVAL',now())
                """,shipmentItem,shipment,orderItem,shipmentNo,goods,new BigDecimal(shippedQty),new BigDecimal(invoiceAmount),new BigDecimal(invoiceAmount),"SUM-G-"+suffix);
        confirmShipmentSource(shipment, actorUser, actor);
        ledger(invoice,"SALES_SHIPMENT",shipment,shipmentNo,client,currency,new BigDecimal(invoiceAmount),new BigDecimal(invoiceBalance));
        jdbc.update("""
                INSERT INTO ar_ap_source_refs(id,ledger_id,source_type,source_id,source_no,source_sequence,amount_original,amount_local)
                VALUES(gen_random_uuid(),?,'SALES_ORDER',?,?,1,?,?)
                """,invoice,order,orderNo,new BigDecimal(invoiceAmount),new BigDecimal(invoiceAmount));
        jdbc.update("""
                INSERT INTO sales_returns(id,bill_no,bill_date,client_id,currency_id,exchange_rate,tax_rate,
                    status,ar_posted,source_shipment_id,total_original,total_local)
                VALUES(?,?,DATE '2026-09-07',?,?,1,0,1,TRUE,?,?,?)
                """,returned,returnNo,client,currency,shipment,new BigDecimal(returnAmount),new BigDecimal(returnAmount));
        jdbc.update("""
                INSERT INTO sales_return_items(id,return_id,out_item_id,order_item_id,bill_no,bill_date,goods_id,
                    qty,price,amount_original,amount_local,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at)
                VALUES(gen_random_uuid(),?,?,?,?,DATE '2026-09-07',?,?,10,?,?,?,'Summary goods','SHIPMENT_ITEM_AT_APPROVAL',now())
                """,returned,shipmentItem,orderItem,returnNo,goods,new BigDecimal(returnedQty),new BigDecimal(returnAmount),new BigDecimal(returnAmount),"SUM-G-"+suffix);
        ledger(UUID.randomUUID(),"SALES_RETURN",returned,returnNo,client,currency,new BigDecimal(returnAmount).negate(),new BigDecimal(returnBalance));
        return order;
    }

    /** Query fixture: persist the actual current submission and claimed finance decision before AR recognition. */
    private void confirmShipmentSource(UUID shipment, UUID actorUser, UUID actorEmployee) {
        jdbc.update("""
                INSERT INTO sales_shipment_submission_events(
                    shipment_id,review_revision,content_hash,commercial_snapshot,actor_user_id,actor_employee_id,occurred_at)
                SELECT id,review_revision,fn_customer_shipment_snapshot_hash(fn_customer_shipment_commercial_snapshot(id)),
                    fn_customer_shipment_commercial_snapshot(id)::jsonb,?,?,now()
                FROM sales_shipments WHERE id=?
                """,actorUser,actorEmployee,shipment);
        jdbc.update("""
                UPDATE sales_shipments SET sales_confirmed_revision=review_revision,
                    sales_confirmed_at=now(),sales_confirmed_by=? WHERE id=?
                """,actorEmployee,shipment);
        UUID claim=UUID.randomUUID();
        jdbc.update("""
                INSERT INTO task_claims(id,target_type,target_key,claimed_by,lease_until)
                VALUES(?,'SALES_SHIPMENT_FINANCE_AUDIT',?,?,now()+INTERVAL '30 minutes')
                """,claim,shipment.toString(),actorEmployee);
        UUID release=UUID.randomUUID();
        jdbc.update("""
                INSERT INTO sales_shipment_finance_release_events(
                    id,shipment_id,event_type,actor_user_id,occurred_at,client_id,client_name,currency_id,
                    sales_payment_type,shipment_total_original,formal_ar_outstanding_local,credit_floor_local,
                    over_floor_local,available_prepayment_original,available_prepayment_local,
                    review_revision,claim_id,content_hash,commercial_snapshot,billing_mode)
                SELECT ?,s.id,'RELEASED',?,now(),s.client_id,c.name,s.currency_id,
                    c.sales_payment_type,s.total_original,0,0,0,0,0,
                    s.review_revision,?,submitted.content_hash,submitted.commercial_snapshot,s.billing_mode
                FROM sales_shipments s JOIN clients c ON c.id=s.client_id
                JOIN sales_shipment_submission_events submitted
                  ON submitted.shipment_id=s.id AND submitted.review_revision=s.review_revision
                WHERE s.id=?
                """,release,actorUser,claim,shipment);
        jdbc.update("""
                UPDATE sales_shipments SET finance_audit=1,finance_auditor_id=?,finance_audited_at=now(),
                    finance_release_event_id=? WHERE id=?
                """,actorUser,release,shipment);
        jdbc.update("""
                UPDATE task_claims SET released_at=now(),released_by=?,release_reason='completed' WHERE id=?
                """,actorEmployee,claim);
        jdbc.update("""
                UPDATE sales_shipments SET status=1,warehouse_work_status='SHIPPED',
                    handed_over_at=now(),handed_over_by=?,ar_posted=TRUE WHERE id=?
                """,actorEmployee,shipment);
    }

    private static void assertMoney(String actual, String expected) {
        // Exact DTO text keeps the original decimal; display padding is not a money fact.
        assertThat(actual).isNotNull();
        assertThat(new BigDecimal(actual)).isEqualByComparingTo(expected);
    }

    private void ledger(UUID id,String type,UUID source,String billNo,UUID client,UUID currency,BigDecimal amount,BigDecimal balance) {
        jdbc.update("""
                INSERT INTO ar_ap_ledger(id,direction,source_doc_type,source_doc_id,source_doc_no,bill_no,bill_date,
                    client_id,currency_id,exchange_rate,amount_original,amount_original_local,
                    amount_balance_original,amount_balance,amount_settled,
                    amount_received_original,amount_received_local,amount_write_off_original,amount_write_off_local,
                    is_settled,settled_date,status)
                VALUES(?,'AR',?,?,?,?,DATE '2026-09-07',?,?,1,?,?,?,?,?,?,?,0,0,?,?,1)
                """,id,type,source,billNo,billNo,client,currency,amount,amount,balance,balance,
                amount.subtract(balance),amount.subtract(balance),amount.subtract(balance),balance.signum()==0,
                balance.signum()==0 ? java.time.LocalDate.of(2026,9,7) : null);
    }
}
