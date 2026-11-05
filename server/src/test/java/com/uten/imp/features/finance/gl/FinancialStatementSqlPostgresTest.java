package com.uten.imp.features.finance.gl;

import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Independent balanced journals exercise statement SQL, account allocation and final formulas together. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinancialStatementSqlPostgresTest {
    // Explicit inputs for these scenarios; finite source values remain exact.
    private static java.util.Map<String, com.uten.imp.common.finance.BusinessPrecisionContext.Choice> scenarioChoices() {
        return java.util.Map.of(
                "report.percentage", new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(2, "HALF_UP"));
    }
    private final AutoCloseable scenarioPrecision = com.uten.imp.common.finance.BusinessPrecisionContext.use(scenarioChoices());
    @org.junit.jupiter.api.AfterEach void releaseScenarioPrecision() throws Exception { scenarioPrecision.close(); }

    private static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine");
    private static JdbcTemplate db;
    private static NamedParameterJdbcTemplate named;
    private FinancialStatementService statements;

    @BeforeAll static void start() {
        PG.start();
        var source = new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword());
        db = new JdbcTemplate(source); named = new NamedParameterJdbcTemplate(source);
        db.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto");
        MigratedProjectionSchema.createCurrentTables(db,"payment_styles","gl_entries","gl_vouchers","finance_report_line_bindings",
                "finance_report_line_confirmations","fixed_assets","deferred_expenses","system_posting_style_roles",
                "legacy_migration_runs","legacy_migration_run_files","finance_gl_period_versions",
                "finance_accounting_period_coverage","finance_gl_voucher_evidence","finance_gl_opening_baselines","finance_accounting_import_batches");
        MigratedProjectionSchema.createCurrentFunctions(db,"fn_legacy_payment_style_source_root_matches","fn_finance_entry_is_pnl_closing","fn_finance_gl_voucher_is_booked","fn_finance_balance_asof_complete");
    }

    @AfterAll static void stop() { PG.stop(); }

    @BeforeEach void journals() {
        db.execute("TRUNCATE payment_styles,gl_entries,gl_vouchers,finance_report_line_bindings,finance_report_line_confirmations,fixed_assets,deferred_expenses,system_posting_style_roles,finance_gl_period_versions,finance_accounting_period_coverage,finance_gl_voucher_evidence,finance_gl_opening_baselines,finance_accounting_import_batches");
        db.execute("INSERT INTO finance_gl_period_versions(period) SELECT '2026-'||lpad(n::text,2,'0') FROM generate_series(1,12) n");
        db.execute("INSERT INTO finance_accounting_period_coverage(period,entries_revision,source_kind,source_sha256,verified_by) SELECT period,revision,'ANONYMIZED_COMPLETE_JOURNAL',repeat('0',64),gen_random_uuid() FROM finance_gl_period_versions");
        var em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call -> query(call.getArgument(0)));
        statements = new FinancialStatementService(em);
        UUID cash=style("ACCOUNT","BS_1"), receivable=style("ACCOUNT","BS_4"), fixed=style("ACCOUNT","BS_18"),
                accumulated=style("ACCOUNT","BS_19"), capital=style("EQUITY","BS_48"),
                revenue=style("INCOME","PL_1"), costs=style("EXPENSE","PL_2"), admin=style("EXPENSE","PL_14");
        for(var line:FinancialStatementCatalog.all()) if(line.direct()) {
            Integer bindings=db.queryForObject("SELECT count(*) FROM finance_report_line_bindings WHERE line_key=?",Integer.class,line.key());
            if(bindings==0) db.update("INSERT INTO finance_report_line_confirmations(line_key,confirmed_zero) VALUES(?,true)",line.key());
        }
        // Seed capital, then acquire an asset, sell, pay a cost, depreciate, and sell next month.
        journal("2025-12-31",cash,capital,"1000");
        journal("2026-01-10",fixed,cash,"600");
        journal("2026-01-15",receivable,revenue,"500");
        journal("2026-01-20",costs,cash,"200");
        journal("2026-01-31",admin,accumulated,"100");
        journal("2026-02-01",receivable,revenue,"100");
        // Deleted data must never affect balances or profits.
        journal("2026-01-25",receivable,revenue,"9999");
        db.update("UPDATE gl_entries SET is_deleted=true WHERE amount=9999");
        UUID baselineBatch=UUID.randomUUID();
        db.update("INSERT INTO finance_accounting_import_batches(id,actor_id,source_name,storage_provider,storage_key,storage_size,sha256,source_system,preview,status,result) VALUES(?,gen_random_uuid(),'anonymous.xls','test','test',1,repeat('0',64),'TEST','{}','POSTED','{}')",baselineBatch);
        db.update("INSERT INTO finance_gl_opening_baselines(effective_from,import_batch_id,source_sha256,verified_by) VALUES(DATE '2026-01-01',?,repeat('0',64),gen_random_uuid())",baselineBatch);
        db.update("INSERT INTO finance_gl_voucher_evidence(voucher_id,import_batch_id,purpose,source_system,source_ledger,source_year,source_period,source_voucher_type,source_voucher_no,source_sha256,source_snapshot,submitted_by,approved_by) SELECT voucher_id,?,'OPENING','TEST','TEST',2026,1,'OPENING',voucher_id::text,repeat('0',64),'{}'::jsonb,gen_random_uuid(),gen_random_uuid() FROM (SELECT DISTINCT voucher_id FROM gl_entries WHERE entry_date<DATE '2026-01-01') source",baselineBatch);
    }

    @Test void monthEndBalancesAndOpeningValuesReconcileToTheIndependentBalancedJournals() {
        var rows=statements.balance(LocalDate.of(2026,1,31));
        amount(rows,1,"periodEnd","200");amount(rows,4,"periodEnd","500");
        amount(rows,18,"periodEnd","600");amount(rows,19,"periodEnd","100");
        amount(rows,20,"periodEnd","500");amount(rows,51,"periodEnd","200");
        amount(rows,30,"periodEnd","1200");amount(rows,53,"periodEnd","1200");
        amount(rows,1,"yearStart","1000");amount(rows,48,"yearStart","1000");
        amount(rows,30,"yearStart","1000");amount(rows,53,"yearStart","1000");
    }

    @Test void monthlyProfitsRespectMonthBoundariesAndMissingMappingsRemainUnknown() {
        var rows=statements.profit(2026,2);
        amount(rows,1,"m1","500");amount(rows,1,"m2","100");
        amount(rows,2,"m1","200");amount(rows,14,"m1","100");
        amount(rows,32,"m1","200");amount(rows,32,"m2","100");
        var unknown=style("EXPENSE",null);
        UUID extra=voucher("2026-02-02");
        db.update("INSERT INTO gl_entries(voucher_id,style_id,direction,amount,entry_date,period) VALUES(?,?,1,10,DATE '2026-02-02','2026-02')",extra,unknown);
        var incomplete=statements.profit(2026,2);
        amount(incomplete,32,"m1","200");
        assertThat(incomplete.stream().filter(row->row.get("lineNo").equals(32)).findFirst().orElseThrow().get("m2")).isNull();
    }

    @Test void annualAdjustmentIsExplicitAndNeverChangesTheMonthlyStatement() {
        UUID cash=db.queryForObject("SELECT style_id FROM finance_report_line_bindings WHERE line_key='BS_1'",UUID.class);
        UUID adjustment=style("EQUITY","PL_PRIOR_ADJUSTMENT");
        db.update("DELETE FROM finance_report_line_confirmations WHERE line_key='PL_PRIOR_ADJUSTMENT'");
        journal("2026-01-25",adjustment,cash,"25");
        var monthly=statements.profit(2026,1);amount(monthly,32,"m1","200");
        assertThat(monthly).hasSize(20);
        var annual=statements.profitAnnual(2026);
        assertThat(annual).hasSize(21);amount(annual,33,"m1","25");amount(annual,32,"m1","175");
        FinancialStatementAnnual.totals(annual);amount(annual,32,"yearTotal","275");
        db.update("DELETE FROM finance_report_line_bindings WHERE line_key='PL_PRIOR_ADJUSTMENT'");
        var pending=statements.profitAnnual(2026);
        assertThat(pending.stream().filter(r->Integer.valueOf(32).equals(r.get("lineNo"))).findFirst().orElseThrow().get("m1")).isNull();
    }
    @Test void mappingOneNewAccountDoesNotSilentlyDropOtherAuthoritativeNativePostingAccounts() {
        UUID receivable=db.queryForObject("SELECT style_id FROM finance_report_line_bindings WHERE line_key='BS_4'",UUID.class);
        UUID oldRevenue=style("INCOME",null);
        db.update("INSERT INTO system_posting_style_roles(role_key,style_id,required_category,description) VALUES('SALES_REVENUE',?,'INCOME','anonymous fixture')",oldRevenue);
        journal("2026-01-25",receivable,oldRevenue,"50");
        amount(statements.profit(2026,1),1,"m1","550");
        db.update("DELETE FROM finance_report_line_confirmations WHERE line_key='PL_20'");
        db.update("INSERT INTO finance_report_line_bindings(line_key,binding_kind,style_id) VALUES('PL_20','STYLE',?)",oldRevenue);
        amount(statements.profit(2026,1),1,"m1","500");amount(statements.profit(2026,1),20,"m1","50");
    }
    @Test void draftHeaderIsNotBookedAndRealReversalRetainsBothSignedSides() {
        UUID cash=db.queryForObject("SELECT style_id FROM finance_report_line_bindings WHERE line_key='BS_1'",UUID.class);
        UUID admin=db.queryForObject("SELECT style_id FROM finance_report_line_bindings WHERE line_key='PL_14'",UUID.class);
        UUID draft=voucher("2026-01-21");db.update("UPDATE gl_vouchers SET status=0 WHERE id=?",draft);
        db.update("INSERT INTO gl_entries(voucher_id,style_id,direction,amount,entry_date,period) VALUES(?,?,1,10000,DATE '2026-01-21','2026-01')",draft,admin);
        UUID original=voucher("2026-01-22"),reversal=voucher("2026-01-23");
        db.update("INSERT INTO gl_entries(voucher_id,style_id,direction,amount,entry_date,period) VALUES(?,?,1,25,DATE '2026-01-22','2026-01'),(?,?,-1,25,DATE '2026-01-22','2026-01')",original,admin,original,cash);
        db.update("INSERT INTO gl_entries(voucher_id,style_id,direction,amount,entry_date,period) VALUES(?,?,-1,25,DATE '2026-01-23','2026-01'),(?,?,1,25,DATE '2026-01-23','2026-01')",reversal,admin,reversal,cash);
        db.update("UPDATE gl_vouchers SET status=-1,reversed_by_voucher_id=? WHERE id=?",reversal,original);
        db.update("UPDATE gl_vouchers SET reversal_of_voucher_id=? WHERE id=?",original,reversal);
        amount(statements.profit(2026,1),14,"m1","100");amount(statements.balance(LocalDate.of(2026,1,31)),1,"periodEnd","200");
    }

    @Test void verifiedClosingIsExcludedFromProfitAndChangedCertificationDoesNotEraseRealPostedFacts() {
        UUID revenue=db.queryForObject("SELECT style_id FROM finance_report_line_bindings WHERE line_key='PL_1'",UUID.class);
        UUID retained=style("EQUITY","BS_51");
        db.update("DELETE FROM finance_report_line_confirmations WHERE line_key='BS_51'");
        UUID close=voucher("2026-01-31");
        for(var entry:Map.of(revenue,1,retained,-1).entrySet())
            db.update("INSERT INTO gl_entries(voucher_id,style_id,direction,amount,entry_date,period) VALUES(?,?,?,500,DATE '2026-01-31','2026-01')",close,entry.getKey(),entry.getValue());
        db.update("INSERT INTO finance_gl_voucher_evidence(voucher_id,purpose,source_system,source_ledger,source_year,source_period,source_voucher_type,source_voucher_no,source_sha256,source_snapshot,submitted_by,approved_by) VALUES(?,'PNL_CLOSE','TEST','TEST',2026,1,'记','0008',repeat('0',64),'{}',gen_random_uuid(),gen_random_uuid())",close);
        amount(statements.profit(2026,1),1,"m1","500");
        amount(statements.balance(LocalDate.of(2026,1,31)),51,"periodEnd","200");
        db.update("UPDATE finance_gl_period_versions SET revision=revision+1 WHERE period='2026-02'");
        var rows=statements.profit(2026,2);
        amount(rows,1,"m1","500");
        amount(rows,1,"m2","100");
        FinancialStatementAnnual.totals(rows,2);amount(rows,32,"yearTotal","300");
    }

    private static UUID style(String category,String line) {
        UUID id=UUID.randomUUID();
        db.update("INSERT INTO payment_styles(id,code,name,category,level) VALUES(?,?,'同名科目',?,0)",id,"RANDOM-"+id,category);
        if(line!=null) db.update("INSERT INTO finance_report_line_bindings(line_key,binding_kind,style_id) VALUES(?,'STYLE',?)",line,id);
        return id;
    }

    private static void journal(String date,UUID debit,UUID credit,String amount) {
        UUID voucher=voucher(date);
        for(var entry:Map.of(debit,1,credit,-1).entrySet())
            db.update("INSERT INTO gl_entries(voucher_id,style_id,direction,amount,entry_date,period) VALUES(?,?,?,?::numeric,?::date,?)",
                    voucher,entry.getKey(),entry.getValue(),amount,date,date.substring(0,7));
    }
    private static UUID voucher(String date){UUID id=UUID.randomUUID();db.update("INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type) VALUES(?,?,?,?::date,'MANUAL','ANONYMOUS')",id,id.toString(),date.substring(0,7),date);return id;}

    private static void amount(java.util.List<Map<String,Object>> rows,int line,String key,String expected) {
        var row=rows.stream().filter(value->value.get("lineNo").equals(line)).findFirst().orElseThrow();
        assertThat((BigDecimal)row.get(key)).as("line %s %s",line,key).isEqualByComparingTo(expected);
    }

    private static Query query(String sql) {
        Map<String,Object> parameters=new LinkedHashMap<>();
        return mock(Query.class,call->{
            if(call.getMethod().getName().equals("setParameter")){parameters.put(call.getArgument(0),call.getArgument(1));return call.getMock();}
            if(call.getMethod().getName().equals("getSingleResult"))return named.queryForObject(sql,parameters,Object.class);
            if(call.getMethod().getName().equals("getResultList"))return named.query(sql,parameters,(rs,index)->{
                Object[] row=new Object[rs.getMetaData().getColumnCount()];
                for(int i=0;i<row.length;i++) {
                    row[i]=rs.getObject(i+1);
                }
                return row;
            });
            return org.mockito.Answers.RETURNS_DEFAULTS.answer(call);
        });
    }
}
