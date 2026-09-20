package com.uten.imp.features.finance.gl;

import com.uten.imp.security.TxSessionVars;
import org.flywaydb.core.Flyway;
import org.hibernate.SessionFactory;
import org.hibernate.cfg.Configuration;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

/** Real current DDL plus Hibernate-native SQL: legacy is a writer boundary, never a reporting filter. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class GlPostingLegacyCashScopePostgresTest {
    private static final PostgreSQLContainer<?> DATABASE=new PostgreSQLContainer<>("postgres:16-alpine")
            .withUsername("uten").withPassword("synthetic-gl-boundary-only");
    private static final LocalDate DATE=LocalDate.of(2025,1,2);
    private static final UUID OLD_EXPENSE=UUID.randomUUID(), NEW_EXPENSE=UUID.randomUUID(), OLD_VOUCHER=UUID.randomUUID();
    private static final UUID UNPROVEN_VOUCHER=UUID.randomUUID();
    private static final UUID BANK_STYLE=UUID.randomUUID(), EXPENSE_STYLE=UUID.randomUUID(), ACCOUNT=UUID.randomUUID();
    private static final UUID CURRENCY=UUID.randomUUID();
    private static JdbcTemplate jdbc;
    private static SessionFactory sessions;
    private static List<String> originalHead, originalVoucher, originalEntries;
    private static List<String> unprovenVoucher, unprovenEntries;

    @BeforeAll static void start() {
        DATABASE.start();
        jdbc=new JdbcTemplate(new DriverManagerDataSource(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword()));
        Flyway.configure().dataSource(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword()).target("265").load().migrate();
        jdbc.update("INSERT INTO payment_styles(id,code,name,category,level) VALUES (?, 'GL-OLD-BANK','历史账户','ACCOUNT',0),(?,'GL-OLD-COST','历史费用','EXPENSE',0)",BANK_STYLE,EXPENSE_STYLE);
        jdbc.update("INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type) VALUES (?,'unproven-old-cash','2025-01',?,'AUTO','EXPENSE')",UNPROVEN_VOUCHER,DATE);
        jdbc.update("""
                INSERT INTO gl_entries(voucher_id,line_no,style_id,direction,amount,entry_date,period,source_doc_type)
                VALUES (?,1,?,1,1,?,'2025-01','EXPENSE'),(?,2,?,-1,0,?,'2025-01','EXPENSE')
                """,UNPROVEN_VOUCHER,EXPENSE_STYLE,DATE,UNPROVEN_VOUCHER,BANK_STYLE,DATE);
        Flyway.configure().dataSource(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword()).target("625").load().migrate();
        assertThat(jdbc.queryForObject("SELECT source_doc_id FROM gl_vouchers WHERE id=?",UUID.class,UNPROVEN_VOUCHER)).isNull();
        unprovenVoucher=jsonRows("gl_vouchers","id='"+UNPROVEN_VOUCHER+"'");
        unprovenEntries=jsonRows("gl_entries","voucher_id='"+UNPROVEN_VOUCHER+"'");
        jdbc.update("INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES (?,'GL-CNY','人民币',1,'使用')",CURRENCY);
        jdbc.update("INSERT INTO accounts(id,code,name,account_type,status,style_id,currency_id) VALUES (?,'GL-OLD-ACCOUNT','历史账户','CASH','使用',?,?)",ACCOUNT,BANK_STYLE,CURRENCY);
        expense(OLD_EXPENSE,906100,"YF20250102000002","4",1);
        jdbc.update("""
                INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type,source_doc_id,remark)
                VALUES (?,'YF20250102000002','2025-01',?,'AUTO','EXPENSE',?,'existing old posting; preserve identity and bytes')
                """,OLD_VOUCHER,DATE,OLD_EXPENSE);
        jdbc.update("""
                INSERT INTO gl_entries(voucher_id,line_no,style_id,direction,amount,entry_date,period,source_doc_type,source_doc_id)
                VALUES (?,1,?,1,4,?,'2025-01','EXPENSE',?),(?,2,?,-1,4,?,'2025-01','EXPENSE',?)
                """,OLD_VOUCHER,EXPENSE_STYLE,DATE,OLD_EXPENSE,OLD_VOUCHER,BANK_STYLE,DATE,OLD_EXPENSE);
        jdbc.update("UPDATE finance_expenses SET gl_voucher_id=?,gl_status=2 WHERE id=?",OLD_VOUCHER,OLD_EXPENSE);
        // The pre-V626 imported V0 receipt may lack a proved original GL; generator must not invent it.
        jdbc.update("""
                INSERT INTO finance_receipts(legacy_id,bill_no,bill_date,account_id,amount_original,amount_local,status,receipt_kind)
                VALUES (906101,'XS20250102000001',?, ?,3,3,1,'CUSTOMER_PREPAYMENT')
                """,DATE,ACCOUNT);
        // A historical V0 payment must not trigger the native payment-authority gate for the entire period.
        jdbc.update("INSERT INTO finance_payments(legacy_id,bill_no,bill_date,account_id,amount_original,amount_local,status) VALUES (906102,'CF20250102000001',?,?,8,8,1)",DATE,ACCOUNT);
        originalHead=jsonRows("finance_expenses","id='"+OLD_EXPENSE+"'");
        originalVoucher=jsonRows("gl_vouchers","id='"+OLD_VOUCHER+"'");
        originalEntries=jsonRows("gl_entries","voucher_id='"+OLD_VOUCHER+"'");
        Flyway.configure().dataSource(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword()).load().migrate();
        assertThat(jdbc.queryForObject("SELECT legacy_import_run_id FROM finance_expenses WHERE id=?",UUID.class,OLD_EXPENSE))
                .as("A forward schema extension must not invent new source proof for old data").isNull();
        expense(NEW_EXPENSE,null,"YF20250102000001","7",0);
        sessions=new Configuration().setProperty("hibernate.connection.url",DATABASE.getJdbcUrl())
                .setProperty("hibernate.connection.username",DATABASE.getUsername())
                .setProperty("hibernate.connection.password",DATABASE.getPassword())
                .setProperty("hibernate.hbm2ddl.auto","none")
                .setProperty("hibernate.show_sql","false").buildSessionFactory();
    }

    @AfterAll static void stop() {
        if(sessions!=null)sessions.close();
        DATABASE.stop();
    }

    @Test void mixedPeriodPreservesOldCashAndVoucherButRebuildsNativeExpenseAndReportsBoth() {
        for(int replay=0;replay<2;replay++) {
            try(var session=sessions.openSession()) {
                var tx=session.beginTransaction();
                int count=new GlPostingService(session,mock(TxSessionVars.class)).generate("2025-01");
                assertThat(count).as("Only the native managed expense belongs to this generation count").isEqualTo(1);
                tx.commit();
            }
            assertThat(jsonRows("finance_expenses","id='"+OLD_EXPENSE+"'")).isEqualTo(originalHead);
            assertThat(jsonRows("gl_vouchers","id='"+OLD_VOUCHER+"'")).isEqualTo(originalVoucher);
            assertThat(jsonRows("gl_entries","voucher_id='"+OLD_VOUCHER+"'")).isEqualTo(originalEntries);
            assertThat(jsonRows("gl_vouchers","id='"+UNPROVEN_VOUCHER+"'")).isEqualTo(unprovenVoucher);
            assertThat(jsonRows("gl_entries","voucher_id='"+UNPROVEN_VOUCHER+"'")).isEqualTo(unprovenEntries);
            assertThat(jdbc.queryForObject("SELECT count(*) FROM gl_vouchers WHERE source_doc_id=?",Integer.class,NEW_EXPENSE)).isEqualTo(1);
            assertThat(jdbc.queryForObject("SELECT sum(direction*amount) FROM gl_entries WHERE source_doc_id=?",BigDecimal.class,NEW_EXPENSE)).isEqualByComparingTo("0");
            assertThat(jdbc.queryForObject("SELECT sum(amount) FROM gl_entries WHERE source_doc_id=? AND direction=1",BigDecimal.class,NEW_EXPENSE)).isEqualByComparingTo("7");
        }
        assertThat(jdbc.queryForObject("SELECT reconciliation_state FROM v_receipt_v0_gl_reconciliation WHERE bill_no='XS20250102000001'",String.class))
                .as("The global historical integrity view remains truthful; generator did not synthesize a missing voucher").isEqualTo("MISSING");
        try(var session=sessions.openSession()) {
            var report=new GlReportService(session).trialBalance(DATE.withDayOfMonth(1),DATE.withDayOfMonth(31),1,100);
            assertThat(report.rows()).anySatisfy(row->{
                assertThat(row.get("styleCode")).isEqualTo("GL-OLD-COST");
                assertThat((BigDecimal)row.get("debit")).as("Full ledger still includes legacy4 + unproven historical1 + native7").isEqualByComparingTo("12");
            });
            BigDecimal debit=report.rows().stream().map(row->(BigDecimal)row.get("debit")).reduce(BigDecimal.ZERO,BigDecimal::add);
            BigDecimal credit=report.rows().stream().map(row->(BigDecimal)row.get("credit")).reduce(BigDecimal.ZERO,BigDecimal::add);
            assertThat(debit.subtract(credit)).as("The historical imbalance remains visible in the actual full ledger")
                    .isEqualByComparingTo("1");
        }
    }

    private static void expense(UUID id,Integer legacyId,String billNo,String amount,int glStatus) {
        jdbc.update("""
                INSERT INTO finance_expenses(id,legacy_id,bill_no,bill_date,account_id,amount_original,amount_local,status,gl_status)
                VALUES (?,?,?,?,?,?,?,1,?)
                """,id,legacyId,billNo,DATE,ACCOUNT,new BigDecimal(amount),new BigDecimal(amount),glStatus);
        jdbc.update("""
                INSERT INTO finance_expense_items(expense_id,bill_no,bill_date,expense_style_id,amount_original,amount_local,line_no)
                VALUES (?,?,?,?,?,?,1)
                """,id,billNo,DATE,EXPENSE_STYLE,new BigDecimal(amount),new BigDecimal(amount));
    }

    private static List<String> jsonRows(String table,String condition) {
        return jdbc.queryForList("SELECT (to_jsonb(fact)-'legacy_import_run_id')::text FROM "+table+" fact WHERE "+condition+" ORDER BY id",String.class);
    }
}
