package com.uten.imp.features.finance.report;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class AccountStatementScalePostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES=
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");
    private static final int ACCOUNTS=5;
    private static final int ROWS_PER_ACCOUNT=50_000;
    private static final List<UUID> accountIds=new ArrayList<>();

    @BeforeAll
    static void migrateAndSeed() throws Exception {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load().migrate();
        try(Connection connection=connection()){
            UUID currency=uuid(connection,"""
                    SELECT id FROM currencies
                    WHERE is_base_currency AND status='使用'
                      AND COALESCE(is_deleted,FALSE)=FALSE
                    ORDER BY id LIMIT 1
                    """);
            UUID style=uuid(connection,"""
                    SELECT id FROM payment_styles style
                    WHERE style.category='ACCOUNT' AND style.status='使用'
                      AND COALESCE(style.is_deleted,FALSE)=FALSE
                      AND NOT EXISTS(SELECT 1 FROM payment_styles child
                                     WHERE child.parent_id=style.id
                                       AND COALESCE(child.is_deleted,FALSE)=FALSE)
                    ORDER BY id LIMIT 1
                    """);
            for(int index=0;index<ACCOUNTS;index++){
                UUID account=UUID.randomUUID();
                accountIds.add(account);
                try(PreparedStatement insert=connection.prepareStatement("""
                        INSERT INTO accounts(
                          id,code,name,account_type,currency_id,style_id,
                          init_balance,receipts_total,payments_total,
                          balance_adjustments_total,balance_current,status,is_deleted)
                        VALUES(?,?,?,'BANK',?,?,0,0,0,0,0,'使用',FALSE)
                        """)){
                    insert.setObject(1,account);
                    insert.setString(2,"PF"+index+"900001");
                    insert.setString(3,"五十年流水压测账户"+index);
                    insert.setObject(4,currency);
                    insert.setObject(5,style);
                    assertEquals(1,insert.executeUpdate());
                }
            }
            try(Statement statement=connection.createStatement()){
                statement.execute("ALTER TABLE finance_reconciliations DISABLE TRIGGER USER");
            }
            for(UUID account:accountIds){
                try(PreparedStatement seed=connection.prepareStatement("""
                        INSERT INTO finance_reconciliations(
                          id,bill_no,source_doc_type,source_doc_id,account_id,
                          account_currency_id,in_amount,out_amount,amount_local,
                          bill_date,settled_date,source_remark,remark,
                          entry_kind,created_at,updated_at,is_deleted)
                        SELECT gen_random_uuid(),'PERF-'||series,'INCOME',gen_random_uuid(),?,
                               ?,1,0,1,
                               timestamptz '1976-01-01 00:00:00+08'
                                 +((series-1)%18263)*interval '1 day'
                                 +((series-1)%86400)*interval '1 second',
                               NULL,'容量测试','五十年稳定流水',
                               'POSTING',now(),now(),FALSE
                        FROM generate_series(1,?) series
                        """)){
                    seed.setObject(1,account);
                    seed.setObject(2,currency);
                    seed.setInt(3,ROWS_PER_ACCOUNT);
                    assertEquals(ROWS_PER_ACCOUNT,seed.executeUpdate());
                }
                try(PreparedStatement update=connection.prepareStatement("""
                        UPDATE accounts
                        SET receipts_total=?,balance_current=?
                        WHERE id=?
                        """)){
                    update.setInt(1,ROWS_PER_ACCOUNT);
                    update.setInt(2,ROWS_PER_ACCOUNT);
                    update.setObject(3,account);
                    assertEquals(1,update.executeUpdate());
                }
            }
            try(Statement statement=connection.createStatement()){
                statement.execute("ALTER TABLE finance_reconciliations ENABLE TRIGGER USER");
                statement.execute("SELECT fn_rebuild_account_flow_monthly_summaries(NULL)");
                statement.execute("SELECT fn_assert_account_flow_monthly_integrity(NULL)");
                statement.execute("VACUUM (ANALYZE) finance_reconciliations");
                statement.execute("VACUUM (ANALYZE) account_flow_monthly_summaries");
            }
        }
    }

    @AfterAll
    static void stop(){
        POSTGRES.stop();
    }

    @Test
    void fiftyYearOpeningAndWindowUseCoveringIndexWithoutJvmHistoryScan()
            throws Exception {
        UUID account=accountIds.getFirst();
        String statementSql="""
                WITH account_base AS (
                  SELECT id,currency_id,init_balance FROM accounts WHERE id=?
                ), closed_months AS (
                  SELECT COALESCE(SUM(summary.in_amount-summary.out_amount),0) amount
                  FROM account_base account
                  LEFT JOIN account_flow_monthly_summaries summary
                    ON summary.account_id=account.id
                   AND summary.account_currency_id=account.currency_id
                   AND summary.month_start<DATE '2025-12-01'
                ), current_month_tail AS (
                  SELECT COALESCE(SUM(flow.in_amount-flow.out_amount),0) amount
                  FROM account_base account
                  LEFT JOIN finance_reconciliations flow
                    ON flow.account_id=account.id
                   AND COALESCE(flow.is_deleted,FALSE)=FALSE
                   AND flow.bill_date>=timestamptz '2025-12-01 00:00:00+08'
                   AND flow.bill_date<timestamptz '2025-12-15 00:00:00+08'
                ), opening AS (
                  SELECT account.init_balance+closed.amount+tail.amount AS amount
                  FROM account_base account
                  CROSS JOIN closed_months closed
                  CROSS JOIN current_month_tail tail
                ), windowed AS (
                  SELECT flow.posting_seq,
                         opening.amount+SUM(flow.in_amount-flow.out_amount) OVER(
                           ORDER BY flow.bill_date,flow.posting_seq) balance
                  FROM finance_reconciliations flow CROSS JOIN opening
                  WHERE flow.account_id=?
                    AND COALESCE(flow.is_deleted,FALSE)=FALSE
                    AND flow.bill_date>=timestamptz '2025-12-15 00:00:00+08'
                    AND flow.bill_date<timestamptz '2026-01-01 00:00:00+08'
                )
                SELECT posting_seq,balance FROM windowed
                ORDER BY posting_seq LIMIT 100
                """;
        String plan;
        Instant started=Instant.now();
        try(Connection connection=connection();
            PreparedStatement explain=connection.prepareStatement(
                    "EXPLAIN (ANALYZE,BUFFERS,FORMAT TEXT) "+statementSql)){
            explain.setObject(1,account);
            explain.setObject(2,account);
            try(ResultSet rows=explain.executeQuery()){
                StringBuilder text=new StringBuilder();
                while(rows.next())text.append(rows.getString(1)).append('\n');
                plan=text.toString();
            }
        }
        Duration elapsed=Duration.between(started,Instant.now());
        System.out.println("ACCOUNT_STATEMENT_SCALE rows="
                +(ACCOUNTS*ROWS_PER_ACCOUNT)+" years=50 elapsedMs="
                +elapsed.toMillis()+"\n"+plan);
        assertTrue(plan.contains("account_flow_monthly_summaries"),plan);
        assertTrue(plan.contains("idx_frec_account_date_stable"),plan);
        assertTrue(!plan.contains("Seq Scan on finance_reconciliations"),plan);
        assertTrue(!plan.contains("Seq Scan on account_flow_monthly_summaries"),plan);
        assertTrue(elapsed.compareTo(Duration.ofSeconds(5))<0,
                "250k-row five-account statement exceeded 5s: "+elapsed+"\n"+plan);

        Set<Long> firstPage=page(statementSql,account,0);
        Set<Long> secondPage=page(statementSql+" OFFSET 100",account,0);
        Set<Long> overlap=new HashSet<>(firstPage);
        overlap.retainAll(secondPage);
        assertTrue(overlap.isEmpty(),"stable posting_seq pages overlapped: "+overlap);
    }

    @Test
    void cachedBalancesEqualAppendOnlyFlowRebuild() throws Exception {
        try(Connection connection=connection();
            Statement statement=connection.createStatement();
            ResultSet rows=statement.executeQuery("""
                    SELECT COUNT(*) FROM v_account_balance_integrity
                    WHERE account_id::text LIKE '%'
                      AND account_id IN (
                        SELECT id FROM accounts WHERE name LIKE '五十年流水压测账户%')
                      AND balance_difference<>0
                    """)){
            assertTrue(rows.next());
            assertEquals(0,rows.getLong(1));
        }
        try(Connection connection=connection();
            Statement statement=connection.createStatement();
            ResultSet rows=statement.executeQuery("""
                    SELECT COUNT(*) FROM v_account_flow_migration_exceptions
                    WHERE account_id IN (
                      SELECT id FROM accounts WHERE name LIKE '五十年流水压测账户%')
                    """)){
            assertTrue(rows.next());
            assertEquals(0,rows.getLong(1));
        }
        try(Connection connection=connection();
            Statement statement=connection.createStatement()){
            statement.execute("SELECT fn_assert_account_flow_monthly_integrity(NULL)");
            try(ResultSet rows=statement.executeQuery("""
                    SELECT COUNT(*) FROM v_account_flow_monthly_integrity
                    WHERE account_id IN (
                      SELECT id FROM accounts WHERE name LIKE '五十年流水压测账户%')
                      AND NOT is_consistent
                    """)){
                assertTrue(rows.next());
                assertEquals(0,rows.getLong(1));
            }
        }
        UUID account=accountIds.getFirst();
        try(Connection connection=connection();
            PreparedStatement totals=connection.prepareStatement("""
                    SELECT
                      (SELECT COALESCE(SUM(in_amount-out_amount),0)
                       FROM account_flow_monthly_summaries WHERE account_id=?),
                      (SELECT COALESCE(SUM(in_amount-out_amount),0)
                       FROM finance_reconciliations
                       WHERE account_id=? AND COALESCE(is_deleted,FALSE)=FALSE)
                    """)){
            totals.setObject(1,account);
            totals.setObject(2,account);
            try(ResultSet rows=totals.executeQuery()){
                assertTrue(rows.next());
                assertEquals(0,rows.getBigDecimal(1).compareTo(rows.getBigDecimal(2)));
            }
        }
    }

    @Test
    void newAccountFlowRequiresSourceAndBaseCurrencySnapshot() throws Exception {
        UUID account=accountIds.getFirst();
        try(Connection connection=connection()){
            PSQLException missingSource=assertThrows(PSQLException.class,()->{
                try(PreparedStatement insert=connection.prepareStatement("""
                        INSERT INTO finance_reconciliations(
                          id,bill_no,source_doc_type,source_doc_id,account_id,
                          in_amount,out_amount,amount_local,bill_date,
                          entry_kind,is_deleted)
                        VALUES(gen_random_uuid(),'GUARD-NO-SOURCE','INCOME',NULL,?,
                               1,0,1,now(),'POSTING',FALSE)
                        """)){
                    insert.setObject(1,account);
                    insert.executeUpdate();
                }
            });
            assertEquals("23514",missingSource.getSQLState());

            PSQLException wrongBaseSnapshot=assertThrows(PSQLException.class,()->{
                try(PreparedStatement insert=connection.prepareStatement("""
                        INSERT INTO finance_reconciliations(
                          id,bill_no,source_doc_type,source_doc_id,account_id,
                          in_amount,out_amount,amount_local,bill_date,
                          entry_kind,is_deleted)
                        VALUES(gen_random_uuid(),'GUARD-BASE-MISMATCH','INCOME',?, ?,
                               1,0,2,now(),'POSTING',FALSE)
                        """)){
                    insert.setObject(1,UUID.randomUUID());
                    insert.setObject(2,account);
                    insert.executeUpdate();
                }
            });
            assertEquals("23514",wrongBaseSnapshot.getSQLState());
        }
    }

    @Test
    void nullDateFromStartsAtInitAndStillRollsAllRawFacts() throws Exception {
        UUID account=accountIds.get(1);
        try(Connection connection=connection();
            PreparedStatement query=connection.prepareStatement("""
                    WITH account_base AS (
                      SELECT id,currency_id,init_balance FROM accounts WHERE id=?
                    ), closed_months AS (
                      SELECT COALESCE(SUM(summary.in_amount-summary.out_amount),0) amount
                      FROM account_base account
                      LEFT JOIN account_flow_monthly_summaries summary
                        ON summary.account_id=account.id
                       AND summary.account_currency_id=account.currency_id
                       AND CAST(NULL AS date) IS NOT NULL
                    ), current_month_tail AS (
                      SELECT COALESCE(SUM(flow.in_amount-flow.out_amount),0) amount
                      FROM account_base account
                      LEFT JOIN finance_reconciliations flow
                        ON flow.account_id=account.id
                       AND CAST(NULL AS timestamptz) IS NOT NULL
                    ), opening AS (
                      SELECT account.init_balance+closed.amount+tail.amount amount
                      FROM account_base account CROSS JOIN closed_months closed
                      CROSS JOIN current_month_tail tail
                    ), windowed AS (
                      SELECT flow.bill_date,flow.posting_seq,
                             opening.amount+SUM(flow.in_amount-flow.out_amount) OVER(
                               ORDER BY flow.bill_date,flow.posting_seq) balance
                      FROM finance_reconciliations flow CROSS JOIN opening
                      WHERE flow.account_id=? AND COALESCE(flow.is_deleted,FALSE)=FALSE
                    )
                    SELECT balance FROM windowed
                    ORDER BY bill_date DESC,posting_seq DESC LIMIT 1
                    """)){
            query.setObject(1,account);
            query.setObject(2,account);
            try(ResultSet rows=query.executeQuery()){
                assertTrue(rows.next());
                assertEquals(0,rows.getBigDecimal(1)
                        .compareTo(BigDecimal.valueOf(ROWS_PER_ACCOUNT)));
            }
        }
    }

    @Test
    void insertIncrementallyUpsertsShanghaiMonthAndRemainsRebuildable()
            throws Exception {
        UUID account=accountIds.get(ACCOUNTS-1);
        UUID currency;
        BigDecimal beforeAmount;
        long beforeCount;
        try(Connection connection=connection();
            PreparedStatement before=connection.prepareStatement("""
                    SELECT account.currency_id,summary.in_amount,summary.flow_count
                    FROM accounts account
                    JOIN account_flow_monthly_summaries summary
                      ON summary.account_id=account.id
                     AND summary.account_currency_id=account.currency_id
                     AND summary.month_start=DATE '2025-12-01'
                    WHERE account.id=?
                    """)){
            before.setObject(1,account);
            try(ResultSet rows=before.executeQuery()){
                assertTrue(rows.next());
                currency=rows.getObject(1,UUID.class);
                beforeAmount=rows.getBigDecimal(2);
                beforeCount=rows.getLong(3);
            }
        }
        try(Connection connection=connection()){
            connection.setAutoCommit(false);
            try(PreparedStatement insert=connection.prepareStatement("""
                    INSERT INTO finance_reconciliations(
                      id,bill_no,source_doc_type,source_doc_id,account_id,
                      account_currency_id,in_amount,out_amount,amount_local,
                      bill_date,source_remark,remark,entry_kind,is_deleted)
                    VALUES(gen_random_uuid(),'PERF-INCREMENTAL','INCOME',gen_random_uuid(),
                           ?,?,3,0,3,timestamptz '2025-11-30 16:30:00+00',
                           '容量测试','上海十二月增量','POSTING',FALSE)
                    """)){
                insert.setObject(1,account);
                insert.setObject(2,currency);
                assertEquals(1,insert.executeUpdate());
            }
            try(PreparedStatement update=connection.prepareStatement("""
                    UPDATE accounts SET receipts_total=receipts_total+3,
                                        balance_current=balance_current+3
                    WHERE id=?
                    """)){
                update.setObject(1,account);
                assertEquals(1,update.executeUpdate());
            }
            connection.commit();
        }
        try(Connection connection=connection();
            PreparedStatement after=connection.prepareStatement("""
                    SELECT in_amount,flow_count FROM account_flow_monthly_summaries
                    WHERE account_id=? AND account_currency_id=?
                      AND month_start=DATE '2025-12-01'
                    """)){
            after.setObject(1,account);
            after.setObject(2,currency);
            try(ResultSet rows=after.executeQuery()){
                assertTrue(rows.next());
                assertEquals(0,rows.getBigDecimal(1)
                        .compareTo(beforeAmount.add(new BigDecimal("3.0000"))));
                assertEquals(beforeCount+1,rows.getLong(2));
            }
        }
        try(Connection connection=connection();
            PreparedStatement rebuild=connection.prepareStatement(
                    "SELECT fn_rebuild_account_flow_monthly_summaries(?)")){
            rebuild.setObject(1,account);
            assertTrue(rebuild.execute());
        }
        try(Connection connection=connection();
            PreparedStatement verify=connection.prepareStatement("""
                    SELECT fn_assert_account_flow_monthly_integrity(?),
                           (SELECT COUNT(*) FROM v_account_flow_monthly_integrity
                            WHERE account_id=? AND NOT is_consistent)
                    """)){
            verify.setObject(1,account);
            verify.setObject(2,account);
            try(ResultSet rows=verify.executeQuery()){
                assertTrue(rows.next());
                assertEquals(0,rows.getLong(2));
            }
        }
    }

    @Test
    void directSqlCannotCommitV1TerminalReceiptWithoutRealAccountFlow()
            throws Exception {
        UUID receiptId=UUID.randomUUID();
        UUID account=accountIds.get(2);
        UUID maker;
        UUID approver=UUID.randomUUID();
        try(Connection connection=connection()){
            maker=uuid(connection,"""
                    SELECT id FROM employees
                    WHERE status IN ('active','probation','onLeave')
                      AND COALESCE(is_deleted,FALSE)=FALSE
                    ORDER BY id LIMIT 1
                    """);
            try(PreparedStatement employee=connection.prepareStatement("""
                    INSERT INTO employees(
                      id,code,full_name,gender,id_type,hire_date,status,
                      employment_type,department_id,is_deleted)
                    SELECT ?,'FIN-GUARD-APPROVER','财务守卫审核人','female','其他',
                           CURRENT_DATE,'active','regular',department_id,FALSE
                    FROM employees WHERE id=?
                    """)){
                employee.setObject(1,approver);
                employee.setObject(2,maker);
                assertEquals(1,employee.executeUpdate());
            }
        }
        try(Connection connection=connection();
            PreparedStatement insert=connection.prepareStatement("""
                    INSERT INTO finance_receipts(
                      id,bill_no,bill_date,receipt_kind,account_id,currency_id,
                      exchange_rate,amount_original,amount_local,bank_fee,other_fee,
                      status,is_deleted,settlement_authority_version,maker_id,bank_reference,
                      create_idempotency_key,create_request_hash,
                      settlement_channel,settlement_rate_quote_direction,
                      exchange_rate_source,exchange_rate_effective_at,bank_booked_at,
                      account_currency_id,account_exchange_rate,
                      account_exchange_rate_source,account_amount,account_amount_local,
                      bank_fee_account_amount,other_fee_account_amount,
                      fee_settlement_mode,fee_bearer,fee_account_currency_id,
                      fee_account_exchange_rate,gl_account_style_id,gl_counter_style_id)
                    SELECT ?,?,CURRENT_DATE,'CUSTOMER_PREPAYMENT',account.id,
                           account.currency_id,1,10,10,0,0,0,FALSE,1,?,'BANK-GUARD',
                           ?,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                           'DIRECT_ACCOUNT','BASE_PER_SETTLEMENT','BANK_STATEMENT',
                           now(),now(),account.currency_id,1,'BASE_CURRENCY_IDENTITY',
                           10,10,0,0,'NONE','NONE',account.currency_id,1,
                           account.style_id,system_posting_style_id('CUSTOMER_ADVANCE')
                    FROM accounts account WHERE account.id=?
                    """)){
            insert.setObject(1,receiptId);
            insert.setString(2,"XS20991231999999");
            insert.setObject(3,maker);
            insert.setString(4,"guard-"+receiptId);
            insert.setObject(5,account);
            assertEquals(1,insert.executeUpdate());
        }

        try(Connection connection=connection();
            PreparedStatement invalidEvidence=connection.prepareStatement(
                    "UPDATE finance_receipts SET bank_reference=NULL WHERE id=?")){
            invalidEvidence.setObject(1,receiptId);
            PSQLException error=assertThrows(
                    PSQLException.class,invalidEvidence::executeUpdate);
            assertEquals("23514",error.getSQLState());
        }

        try(Connection connection=connection();
            PreparedStatement selfApprove=connection.prepareStatement(
                    "UPDATE finance_receipts SET status=1,approver_id=? WHERE id=?")){
            selfApprove.setObject(1,maker);
            selfApprove.setObject(2,receiptId);
            PSQLException error=assertThrows(
                    PSQLException.class,selfApprove::executeUpdate);
            assertEquals("23514",error.getSQLState());
        }

        SQLException error;
        try(Connection connection=connection()){
            connection.setAutoCommit(false);
            try(PreparedStatement approve=connection.prepareStatement(
                    "UPDATE finance_receipts SET status=1,approver_id=? WHERE id=?")){
                approve.setObject(1,approver);
                approve.setObject(2,receiptId);
                assertEquals(1,approve.executeUpdate());
            }
            error=assertThrows(SQLException.class,connection::commit);
            connection.rollback();
        }
        assertEquals("23514",error.getSQLState());
        assertTrue(error instanceof PSQLException,error.getClass().getName());
        assertEquals("receipt_flow_terminal_guard",
                ((PSQLException)error).getServerErrorMessage().getConstraint());

        try(Connection connection=connection();
            PreparedStatement verify=connection.prepareStatement(
                    "SELECT status FROM finance_receipts WHERE id=?")){
            verify.setObject(1,receiptId);
            try(ResultSet rows=verify.executeQuery()){
                assertTrue(rows.next());
                assertEquals(0,rows.getInt(1));
            }
        }
    }

    private static Set<Long> page(String sql,UUID account,int ignored) throws Exception {
        Set<Long> result=new HashSet<>();
        try(Connection connection=connection();
            PreparedStatement query=connection.prepareStatement(sql)){
            query.setObject(1,account);
            query.setObject(2,account);
            try(ResultSet rows=query.executeQuery()){
                while(rows.next())result.add(rows.getLong(1));
            }
        }
        return result;
    }

    private static UUID uuid(Connection connection,String sql) throws Exception {
        try(Statement statement=connection.createStatement();
            ResultSet rows=statement.executeQuery(sql)){
            assertTrue(rows.next(),sql);
            return rows.getObject(1,UUID.class);
        }
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword());
    }
}
