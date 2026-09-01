package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDate;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class CustomerPrepaymentMigrationPostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16.15-alpine")
                    .withDatabaseName("uten_customer_prepayment")
                    .withUsername("uten")
                    .withPassword("uten");

    @BeforeAll
    static void migrate() {
        POSTGRES.start();
        Flyway.configure().dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").load().migrate();
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void dualEntryCapacityTailReversalImmutabilityAndCancellationAreClosed() throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = seed(connection);
            insertExactOrdinaryReceipt(connection, fixture);
            applyOffset(connection, fixture, 1, "1.0000", ".3334",
                    "-2.0000", "-1.0000", "-.6667", "-.3333",
                    "2.0000", "1.0000", ".6667", ".3333");
            applyOffset(connection, fixture, 2, "1.0000", ".3333",
                    "-1.0000", "0.0000", "-.3333", "0.0000",
                    "1.0000", "0.0000", ".3333", "0.0000");

            assertBalances(connection, fixture.prepaymentLedger(), "0", "0");
            assertBalances(connection, fixture.receivableLedger(), "0", "0");
            assertSourceConsumption(connection, fixture.sourceRef(), "3.0000", "1.0001");
            assertSqlState(connection, "55000", """
                    UPDATE customer_open_item_offset_batches SET reason='tampered'
                    WHERE id=?
                    """, fixture.batch(1));
            assertSqlState(connection, "55000", """
                    UPDATE finance_receipts SET amount_original=99 WHERE id=?
                    """, fixture.prepaymentReceipt());
            assertSqlState(connection, "23514", """
                    UPDATE sales_orders SET is_stopped=TRUE WHERE id=?
                    """, fixture.order());

            reverseOffset(connection, fixture, 2,
                    "-1.0000", "-.3333", "1.0000", ".3333");
            reverseOffset(connection, fixture, 1,
                    "-2.0000", "-.6667", "2.0000", ".6667");
            assertBalances(connection, fixture.prepaymentLedger(), "-2.0000", "-.6667");
            assertBalances(connection, fixture.receivableLedger(), "2.0000", ".6667");
            assertSqlState(connection, "55000", """
                    UPDATE customer_open_item_offsets SET reversed_at=now()+INTERVAL '1 minute'
                    WHERE offset_batch_id=?
                    """, fixture.batch(2));

            // This legacy V0 prepayment has no provable account flow or GL
            // voucher. V407 must reject a direct status flip instead of letting
            // the test manufacture a reversal and unblock order cancellation.
            assertSqlState(connection, "55000", """
                    UPDATE finance_receipts SET status=-1,updated_at=now() WHERE id=?
                    """, fixture.prepaymentReceipt());
            assertSqlState(connection, "23514", """
                    UPDATE sales_orders SET is_stopped=TRUE WHERE id=?
                    """, fixture.order());
            assertThat(singleLong(connection, """
                    SELECT COUNT(*) FROM flyway_schema_history
                    WHERE version='389' AND success=TRUE
                    """)).isEqualTo(1);
            assertThat(singleLong(connection, """
                    SELECT COUNT(*) FROM system_posting_style_roles role
                    JOIN payment_styles style ON style.id=role.style_id
                    WHERE role.role_key='CUSTOMER_ADVANCE'
                      AND role.style_id='37900000-0000-4000-8100-000000000001'::uuid
                      AND style.category='LIABILITY' AND style.status='使用'
                    """)).isEqualTo(1);
            assertThat(singleLong(connection, """
                    SELECT COUNT(*) FROM pg_trigger trigger_row
                    JOIN pg_proc function_row ON function_row.oid=trigger_row.tgfoid
                    WHERE trigger_row.tgname LIKE 'trg_audit%'
                      AND trigger_row.tgrelid IN(
                        'customer_open_item_offset_batches'::regclass,
                        'customer_open_item_offsets'::regclass,
                        'finance_receipt_source_allocations'::regclass)
                      AND function_row.proname IN('fn_audit','fn_audit_redacted')
                    """)).isEqualTo(3);
        }
    }

    private static Fixture seed(Connection c) throws SQLException {
        UUID client=UUID.randomUUID(),currency=UUID.randomUUID(),order=UUID.randomUUID();
        UUID preReceipt=UUID.randomUUID(),preLedger=UUID.randomUUID(),arLedger=UUID.randomUUID();
        UUID sourceRef=UUID.randomUUID(),ordinaryReceipt=UUID.randomUUID(),ordinaryLine=UUID.randomUUID();
        UUID employee=UUID.randomUUID(),user=UUID.randomUUID();
        execute(c,"""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                SELECT ?,'CP-PROBE-EMP','Customer prepayment probe',id_type,department_id,
                       DATE '2026-08-23','active','regular'
                FROM employees WHERE code='ADMIN'
                """,employee);
        execute(c,"""
                INSERT INTO users(id,employee_id,login_account,password_hash,status)
                VALUES(?,?,'cp-probe-user','test-only-not-a-real-password','active')
                """,user,employee);
        execute(c,"INSERT INTO clients(id,code,name,status,code_sequence,sales_payment_type) "
                        + "VALUES(?,?,?,'使用',1,'CASH')",
                client,"CP-"+client,"Customer prepayment probe");
        execute(c,"""
                INSERT INTO currencies(id,code,name,exchange_rate,status)
                VALUES(?,?,?,.333350,'使用')
                """,currency,"CUR-"+currency,"Probe currency");
        execute(c,"""
                INSERT INTO sales_orders(id,bill_no,bill_date,client_id,currency_id,exchange_rate,
                    total_original,total_local,status,is_closed,is_stopped,deposit,shipment_policy)
                VALUES(?, 'XD20260823000001', DATE '2026-08-23', ?, ?, .333350,
                       3.0000,1.0001,1,FALSE,FALSE,0,'ALLOW_PARTIAL')
                """,order,client,currency);
        execute(c,"""
                INSERT INTO finance_receipts(id,bill_no,bill_date,receipt_kind,sales_order_id,
                    client_id,currency_id,exchange_rate,amount_original,amount_local,
                    bank_fee,other_fee,status,is_deleted)
                VALUES(?,'XS20260823000001',DATE '2026-08-23','CUSTOMER_PREPAYMENT',?,
                       ?,?,.333350,2.0000,.6667,0,0,1,FALSE)
                """,preReceipt,order,client,currency);
        execute(c,ledgerSql(),preLedger,"DIRECT_RECEIPT",preReceipt,"XS20260823000001","XS20260823000001",
                client,currency,"0","0","2.0000",".6667","-2.0000",".6667","-.6667");
        execute(c,ledgerSql(),arLedger,"SALES_SHIPMENT",UUID.randomUUID(),"AR-PROBE","AR-PROBE",
                client,currency,"3.0000","1.0001","0","0","3.0000","0","1.0001");
        execute(c,"""
                INSERT INTO ar_ap_source_refs(id,ledger_id,source_type,source_id,source_no,
                    source_sequence,amount_original,amount_local)
                VALUES(?,?,'SALES_ORDER',?,'XD20260823000001',1,3.0000,1.0001)
                """,sourceRef,arLedger,order);
        return new Fixture(client,currency,order,user,preReceipt,preLedger,arLedger,sourceRef,
                ordinaryReceipt,ordinaryLine,new UUID[]{UUID.randomUUID(),UUID.randomUUID()});
    }

    private static String ledgerSql() {
        return """
                INSERT INTO ar_ap_ledger(id,direction,source_doc_type,source_doc_id,source_doc_no,
                    bill_no,bill_date,client_id,currency_id,exchange_rate,
                    amount_original,amount_original_local,amount_received_original,amount_received_local,
                    amount_write_off_original,amount_write_off_local,amount_offset_original,amount_offset_local,
                    amount_balance_original,amount_settled,amount_balance,is_settled,status,is_deleted)
                VALUES(?,'AR',?,?,?, ?,DATE '2026-08-23',?,?,.333350,
                       ?::numeric,?::numeric,?::numeric,?::numeric, 0,0,0,0,
                       ?::numeric,?::numeric,?::numeric,FALSE,1,FALSE)
                """;
    }

    private static void insertExactOrdinaryReceipt(Connection c, Fixture f) throws SQLException {
        transaction(c, () -> {
            execute(c,"""
                    INSERT INTO finance_receipts(id,bill_no,bill_date,receipt_kind,client_id,currency_id,
                        exchange_rate,amount_original,amount_local,bank_fee,other_fee,status,is_deleted)
                    VALUES(?,'XS20260823000002',DATE '2026-08-23','AR_SETTLEMENT',?,?,.333350,
                           1.0000,.3334,0,0,0,FALSE)
                    """,f.ordinaryReceipt(),f.client(),f.currency());
            execute(c,"""
                    INSERT INTO finance_receipt_lines(id,receipt_id,bill_no,bill_date,applied_ledger_id,
                        client_id,line_no,amount_original,amount_local,exchange_diff,currency_id,
                        exchange_rate,write_off_amount,write_off_local,applied_amount_local,
                        balance_before_original,balance_after_original,is_deleted)
                    VALUES(?,?,'XS20260823000002',DATE '2026-08-23',?,?,1,1.0000,.3334,0,?,
                           .333350,0,0,.3334,3.0000,2.0000,FALSE)
                    """,f.ordinaryLine(),f.ordinaryReceipt(),f.receivableLedger(),f.client(),f.currency());
            execute(c,"""
                    UPDATE ar_ap_ledger SET amount_received_original=1.0000,amount_received_local=.3334,
                        amount_balance_original=2.0000,amount_settled=.3334,amount_balance=.6667
                    WHERE id=?
                    """,f.receivableLedger());
            execute(c,"UPDATE finance_receipts SET status=1 WHERE id=?",f.ordinaryReceipt());
            execute(c,"""
                    INSERT INTO finance_receipt_source_allocations(
                        receipt_id,receipt_line_id,ledger_id,source_ref_id,sales_order_id,
                        line_sequence,source_sequence,cash_original,cash_local,write_off_original,
                        write_off_local,applied_book_local,exchange_difference,effective_date,status)
                    VALUES(?,?,?,?,?,1,1,1.0000,.3334,0,0,.3334,0,DATE '2026-08-23','APPLIED')
                    """,f.ordinaryReceipt(),f.ordinaryLine(),f.receivableLedger(),f.sourceRef(),f.order());
        });
    }

    private static void applyOffset(Connection c, Fixture f, int seq, String amount, String local,
                                    String sourceBefore,String sourceAfter,String sourceBeforeLocal,String sourceAfterLocal,
                                    String targetBefore,String targetAfter,String targetBeforeLocal,String targetAfterLocal)
            throws SQLException {
        UUID batch=f.batch(seq);
        transaction(c,()->{
            execute(c,"""
                    INSERT INTO customer_open_item_offset_batches(id,client_id,currency_id,effective_date,
                        status,row_version,idempotency_key,request_hash,reason,applied_by)
                    VALUES(?,?,?,DATE '2026-08-23','APPLIED',0,?,?,?,?)
                    """,batch,f.client(),f.currency(),"probe-"+seq,"hash-"+seq,"probe apply "+seq,f.user());
            execute(c,"""
                    UPDATE ar_ap_ledger SET amount_offset_original=amount_offset_original-?::numeric,
                        amount_offset_local=amount_offset_local-?::numeric,
                        amount_balance_original=?::numeric,amount_balance=?::numeric,
                        is_settled=(?::numeric=0 AND ?::numeric=0),
                        settled_date=CASE WHEN ?::numeric=0 AND ?::numeric=0
                                          THEN DATE '2026-08-23' ELSE NULL END
                    WHERE id=?
                    """,amount,local,sourceAfter,sourceAfterLocal,sourceAfter,sourceAfterLocal,
                    sourceAfter,sourceAfterLocal,f.prepaymentLedger());
            execute(c,"""
                    UPDATE ar_ap_ledger SET amount_offset_original=amount_offset_original+?::numeric,
                        amount_offset_local=amount_offset_local+?::numeric,
                        amount_balance_original=?::numeric,amount_balance=?::numeric,
                        is_settled=(?::numeric=0 AND ?::numeric=0),
                        settled_date=CASE WHEN ?::numeric=0 AND ?::numeric=0
                                          THEN DATE '2026-08-23' ELSE NULL END
                    WHERE id=?
                    """,amount,local,targetAfter,targetAfterLocal,targetAfter,targetAfterLocal,
                    targetAfter,targetAfterLocal,f.receivableLedger());
            execute(c,"""
                    INSERT INTO customer_open_item_offsets(
                        offset_batch_id,line_sequence,client_id,currency_id,source_ledger_id,target_ledger_id,
                        target_source_ref_id,sales_order_id,amount_original,source_amount_local,target_amount_local,
                        exchange_difference,source_rate,target_rate,source_balance_before_original,
                        source_balance_after_original,target_balance_before_original,target_balance_after_original,
                        source_balance_before_local,source_balance_after_local,target_balance_before_local,
                        target_balance_after_local,target_ref_balance_before_original,target_ref_balance_after_original,
                        target_ref_balance_before_local,target_ref_balance_after_local,effective_date,status,row_version)
                    VALUES(?,1,?,?,?,?,?,?,?::numeric,?::numeric,?::numeric,0,.333350,.333350,
                           ?::numeric,?::numeric,?::numeric,?::numeric,?::numeric,?::numeric,
                           ?::numeric,?::numeric,?::numeric,?::numeric,?::numeric,?::numeric,
                           DATE '2026-08-23','APPLIED',0)
                    """,batch,f.client(),f.currency(),f.prepaymentLedger(),f.receivableLedger(),f.sourceRef(),f.order(),
                    amount,local,local,sourceBefore,sourceAfter,targetBefore,targetAfter,sourceBeforeLocal,sourceAfterLocal,
                    targetBeforeLocal,targetAfterLocal,targetBefore,targetAfter,targetBeforeLocal,targetAfterLocal);
        });
    }

    private static void reverseOffset(Connection c, Fixture f, int seq,
                                      String sourceOriginal,String sourceLocal,String targetOriginal,String targetLocal)
            throws SQLException {
        transaction(c,()->{
            execute(c,"""
                    UPDATE ar_ap_ledger SET
                      amount_offset_original=amount_offset_original+
                        (SELECT amount_original FROM customer_open_item_offsets WHERE offset_batch_id=?),
                      amount_offset_local=amount_offset_local+
                        (SELECT source_amount_local FROM customer_open_item_offsets WHERE offset_batch_id=?),
                      amount_balance_original=?::numeric,amount_balance=?::numeric,is_settled=FALSE,settled_date=NULL
                    WHERE id=?
                    """,f.batch(seq),f.batch(seq),sourceOriginal,sourceLocal,f.prepaymentLedger());
            execute(c,"""
                    UPDATE ar_ap_ledger SET
                      amount_offset_original=amount_offset_original-
                        (SELECT amount_original FROM customer_open_item_offsets WHERE offset_batch_id=?),
                      amount_offset_local=amount_offset_local-
                        (SELECT target_amount_local FROM customer_open_item_offsets WHERE offset_batch_id=?),
                      amount_balance_original=?::numeric,amount_balance=?::numeric,is_settled=FALSE,settled_date=NULL
                    WHERE id=?
                    """,f.batch(seq),f.batch(seq),targetOriginal,targetLocal,f.receivableLedger());
            execute(c,"""
                    UPDATE customer_open_item_offsets SET status='REVERSED',row_version=row_version+1,
                        reversed_by=?,reversed_at=now() WHERE offset_batch_id=?
                    """,f.user(),f.batch(seq));
            execute(c,"""
                    UPDATE customer_open_item_offset_batches SET status='REVERSED',row_version=row_version+1,
                        reverse_reason='probe reverse',reversed_by=?,reversed_at=now()
                    WHERE id=?
                    """,f.user(),f.batch(seq));
        });
    }

    private static void assertBalances(Connection c,UUID ledger,String original,String local)throws SQLException{
        try(PreparedStatement statement=c.prepareStatement("SELECT amount_balance_original,amount_balance FROM ar_ap_ledger WHERE id=?")){
            statement.setObject(1,ledger);try(ResultSet rows=statement.executeQuery()){assertThat(rows.next()).isTrue();
                assertThat(rows.getBigDecimal(1)).isEqualByComparingTo(original);
                assertThat(rows.getBigDecimal(2)).isEqualByComparingTo(local);}}
    }

    private static void assertSourceConsumption(Connection c,UUID ref,String original,String local)throws SQLException{
        try(PreparedStatement statement=c.prepareStatement("""
                SELECT COALESCE(SUM(v.original),0),COALESCE(SUM(v.local),0) FROM(
                  SELECT cash_original+write_off_original original,applied_book_local local
                  FROM finance_receipt_source_allocations WHERE source_ref_id=? AND status='APPLIED'
                  UNION ALL SELECT amount_original,target_amount_local FROM customer_open_item_offsets
                  WHERE target_source_ref_id=? AND status='APPLIED')v
                """)){statement.setObject(1,ref);statement.setObject(2,ref);try(ResultSet rows=statement.executeQuery()){
            assertThat(rows.next()).isTrue();assertThat(rows.getBigDecimal(1)).isEqualByComparingTo(original);
            assertThat(rows.getBigDecimal(2)).isEqualByComparingTo(local);}}
    }

    private static void assertSqlState(Connection c,String state,String sql,Object...args)throws SQLException{
        c.setAutoCommit(false);try{assertThatThrownBy(()->execute(c,sql,args)).isInstanceOf(SQLException.class)
                .extracting(error->((SQLException)error).getSQLState()).isEqualTo(state);c.rollback();}
        finally{c.setAutoCommit(true);}
    }

    private static void transaction(Connection c,SqlWork work)throws SQLException{
        c.setAutoCommit(false);try{work.run();c.commit();}catch(SQLException error){c.rollback();throw error;}
        finally{c.setAutoCommit(true);}
    }

    private static void execute(Connection c,String sql,Object...args)throws SQLException{
        try(PreparedStatement statement=c.prepareStatement(sql)){for(int i=0;i<args.length;i++)statement.setObject(i+1,args[i]);statement.executeUpdate();}
    }
    private static Object single(Connection c,String sql)throws SQLException{try(PreparedStatement s=c.prepareStatement(sql);ResultSet r=s.executeQuery()){assertThat(r.next()).isTrue();return r.getObject(1);}}
    private static long singleLong(Connection c,String sql)throws SQLException{return ((Number)single(c,sql)).longValue();}
    private static Connection connection()throws SQLException{return DriverManager.getConnection(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword());}
    @FunctionalInterface private interface SqlWork{void run()throws SQLException;}
    private record Fixture(UUID client,UUID currency,UUID order,UUID user,UUID prepaymentReceipt,
                           UUID prepaymentLedger,UUID receivableLedger,UUID sourceRef,
                           UUID ordinaryReceipt,UUID ordinaryLine,UUID[] batches){UUID batch(int sequence){return batches[sequence-1];}}
}
