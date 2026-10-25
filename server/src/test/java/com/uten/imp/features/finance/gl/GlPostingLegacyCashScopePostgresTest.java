package com.uten.imp.features.finance.gl;

import com.uten.imp.security.TxSessionVars;
import org.hibernate.SessionFactory;
import org.hibernate.cfg.Configuration;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;

/** Separate proofs: old unprovable GL stays before V425; fresh current native GL is executable. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class GlPostingLegacyCashScopePostgresTest {
    private static final PostgreSQLContainer DATABASE=new PostgreSQLContainer("postgres:16-alpine")
            .withUsername("fixture_admin").withPassword("synthetic-gl-boundary-only");
    private static final LocalDate DATE=LocalDate.of(2025,1,2);
    private static final UUID NEW_EXPENSE=UUID.randomUUID();
    private static final UUID BANK_STYLE=UUID.randomUUID(), EXPENSE_STYLE=UUID.randomUUID(), ACCOUNT=UUID.randomUUID();
    private static JdbcTemplate jdbc;
    private static SessionFactory sessions;

    @BeforeAll static void start() {
        DATABASE.start();
        jdbc=database(DATABASE);
        com.uten.imp.testsupport.TestFlyway.configure()
                .dataSource(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword())
                .load().migrate();
        jdbc.update("INSERT INTO payment_styles(id,code,name,category,level) VALUES (?, 'GL-NATIVE-BANK','合成账户','ACCOUNT',0),(?,'GL-NATIVE-COST','合成费用','EXPENSE',0)",BANK_STYLE,EXPENSE_STYLE);
        UUID currency=jdbc.queryForObject("SELECT id FROM currencies WHERE is_base_currency",UUID.class);
        jdbc.update("INSERT INTO accounts(id,code,name,account_type,status,style_id,currency_id) VALUES (?,'GL-NATIVE-ACCOUNT','合成账户','CASH','使用',?,?)",ACCOUNT,BANK_STYLE,currency);
        expense(jdbc,NEW_EXPENSE,null,"YF20250102000001","7",0);
        var configuration=new Configuration().setProperty("hibernate.hbm2ddl.auto","none")
                .setProperty("hibernate.show_sql","false");
        configuration.getProperties().put("hibernate.connection.datasource",jdbc.getDataSource());
        sessions=configuration.buildSessionFactory();
    }

    @AfterAll static void stop() {
        if(sessions!=null)sessions.close();
        DATABASE.stop();
    }

    @Test void freshCurrentNativeExpenseRebuildsBalancedGlAndRejectsNewUnprovableAutoRows() {
        for(int replay=0;replay<2;replay++) {
            try(var session=sessions.openSession()) {
                var tx=session.beginTransaction();
                assertThat(new GlPostingService(session,mock(TxSessionVars.class)).generate("2025-01"))
                        .as("Only the native managed expense belongs to this generation count").isEqualTo(1);
                tx.commit();
            }
            assertThat(jdbc.queryForObject("SELECT count(*) FROM gl_vouchers WHERE source_doc_id=?",Integer.class,NEW_EXPENSE)).isEqualTo(1);
            assertThat(jdbc.queryForObject("SELECT sum(direction*amount) FROM gl_entries WHERE source_doc_id=?",BigDecimal.class,NEW_EXPENSE)).isEqualByComparingTo("0");
            assertThat(jdbc.queryForObject("SELECT sum(amount) FROM gl_entries WHERE source_doc_id=? AND direction=1",BigDecimal.class,NEW_EXPENSE)).isEqualByComparingTo("7");
        }
        try(var session=sessions.openSession()) {
            var report=new GlReportService(session,new GlReportLineSource(session))
                    .trialBalance(DATE.withDayOfMonth(1),DATE.withDayOfMonth(31),1,100);
            assertThat(report.rows()).anySatisfy(row->{
                assertThat(row.get("styleCode")).isEqualTo("GL-NATIVE-COST");
                assertThat((BigDecimal)row.get("debit")).isEqualByComparingTo("7");
            });
            BigDecimal debit=report.rows().stream().map(row->(BigDecimal)row.get("debit")).reduce(BigDecimal.ZERO,BigDecimal::add);
            BigDecimal credit=report.rows().stream().map(row->(BigDecimal)row.get("credit")).reduce(BigDecimal.ZERO,BigDecimal::add);
            assertThat(debit).isEqualByComparingTo(credit);
        }
        assertThatThrownBy(()->jdbc.update("INSERT INTO gl_vouchers(voucher_no,period,voucher_date,source,source_type) VALUES('unproved-new','2025-01',?,'AUTO','EXPENSE')",DATE))
                .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM gl_vouchers WHERE voucher_no='unproved-new'",Integer.class)).isZero();
    }

    @Test void nonemptyHistoricalGlAndItsAuditRemainUnchangedWhenV425IsRefused() {
        try(var historical=new PostgreSQLContainer("postgres:16-alpine")
                .withUsername("fixture_admin").withPassword("synthetic-gl-history-only")) {
            historical.start();
            var configuration=com.uten.imp.testsupport.TestFlyway.configure()
                    .dataSource(historical.getJdbcUrl(),historical.getUsername(),historical.getPassword());
            configuration.target("265").load().migrate();
            JdbcTemplate old=database(historical);
            UUID voucher=UUID.randomUUID(),oldExpense=UUID.randomUUID(),originalVoucher=UUID.randomUUID();
            old.update("INSERT INTO payment_styles(id,code,name,category,level) VALUES (?, 'GL-OLD-BANK','历史账户','ACCOUNT',0),(?,'GL-OLD-COST','历史费用','EXPENSE',0)",BANK_STYLE,EXPENSE_STYLE);
            old.update("INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type) VALUES (?,'unproven-old-cash','2025-01',?,'AUTO','EXPENSE')",voucher,DATE);
            old.update("INSERT INTO gl_entries(voucher_id,line_no,style_id,direction,amount,entry_date,period,source_doc_type) VALUES (?,1,?,1,1,?,'2025-01','EXPENSE'),(?,2,?,-1,0,?,'2025-01','EXPENSE')",voucher,EXPENSE_STYLE,DATE,voucher,BANK_STYLE,DATE);
            configuration.target("424").load().migrate();
            UUID currency=old.queryForObject("SELECT id FROM currencies WHERE is_base_currency",UUID.class);
            old.update("INSERT INTO accounts(id,code,name,account_type,status,style_id,currency_id) VALUES (?,'GL-OLD-ACCOUNT','历史账户','CASH','使用',?,?)",ACCOUNT,BANK_STYLE,currency);
            expense(old,oldExpense,906100,"YF20250102000002","4",0);
            old.update("INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type,source_doc_id,remark) VALUES (?,'YF20250102000002','2025-01',?,'AUTO','EXPENSE',?,'existing old posting; preserve identity and bytes')",originalVoucher,DATE,oldExpense);
            old.update("INSERT INTO gl_entries(voucher_id,line_no,style_id,direction,amount,entry_date,period,source_doc_type,source_doc_id) VALUES (?,1,?,1,4,?,'2025-01','EXPENSE',?),(?,2,?,-1,4,?,'2025-01','EXPENSE',?)",originalVoucher,EXPENSE_STYLE,DATE,oldExpense,originalVoucher,BANK_STYLE,DATE,oldExpense);
            old.update("UPDATE finance_expenses SET gl_voucher_id=?,gl_status=2 WHERE id=?",originalVoucher,oldExpense);
            List<String> before=historicalFacts(old);
            assertThatThrownBy(()->configuration.target("425").load().migrate())
                    .isInstanceOf(org.flywaydb.core.api.FlywayException.class)
                    .hasStackTraceContaining("V425 audit fresh-start is allowed only");
            assertThat(historicalFacts(old)).isEqualTo(before);
            assertThat(old.queryForObject("SELECT source_doc_id FROM gl_vouchers WHERE id=?",UUID.class,voucher)).isNull();
            assertThat(old.queryForObject("SELECT sum(direction*amount) FROM gl_entries WHERE voucher_id=?",BigDecimal.class,voucher))
                    .as("The actual unproven historical imbalance is retained, not repaired or erased").isEqualByComparingTo("1");
            assertThat(old.queryForObject("SELECT max(version::int) FROM flyway_schema_history WHERE success",Integer.class)).isEqualTo(424);
        }
    }

    private static JdbcTemplate database(PostgreSQLContainer postgres) {
        return new JdbcTemplate(new DriverManagerDataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword()));
    }
    private static List<String> historicalFacts(JdbcTemplate db) {
        return db.queryForList("""
                SELECT 'head:'||to_jsonb(h)::text FROM finance_expenses h
                UNION ALL SELECT 'items:'||to_jsonb(i)::text FROM finance_expense_items i
                UNION ALL SELECT 'voucher:'||to_jsonb(v)::text FROM gl_vouchers v
                UNION ALL SELECT 'entry:'||to_jsonb(e)::text FROM gl_entries e
                UNION ALL SELECT 'audit:'||to_jsonb(a)::text FROM audit_log a
                ORDER BY 1
                """,String.class);
    }
    private static void expense(JdbcTemplate db,UUID id,Integer legacyId,String billNo,String amount,int glStatus) {
        db.update("INSERT INTO finance_expenses(id,legacy_id,bill_no,bill_date,account_id,amount_original,amount_local,status,gl_status) VALUES (?,?,?,?,?,?,?,1,?)",
                id,legacyId,billNo,DATE,ACCOUNT,new BigDecimal(amount),new BigDecimal(amount),glStatus);
        db.update("INSERT INTO finance_expense_items(expense_id,bill_no,bill_date,expense_style_id,amount_original,amount_local,line_no) VALUES (?,?,?,?,?,?,1)",
                id,billNo,DATE,EXPENSE_STYLE,new BigDecimal(amount),new BigDecimal(amount));
    }
}
