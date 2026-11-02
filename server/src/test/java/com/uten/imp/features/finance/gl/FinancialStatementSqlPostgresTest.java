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
    private static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine");
    private static JdbcTemplate db;
    private static NamedParameterJdbcTemplate named;
    private FinancialStatementService statements;

    @BeforeAll static void start() {
        PG.start();
        var source = new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword());
        db = new JdbcTemplate(source); named = new NamedParameterJdbcTemplate(source);
        db.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto");
        MigratedProjectionSchema.createCurrentTables(db,"payment_styles","gl_entries","finance_report_line_bindings",
                "finance_report_line_confirmations","fixed_assets","deferred_expenses","system_posting_style_roles",
                "legacy_migration_runs","legacy_migration_run_files");
        MigratedProjectionSchema.createCurrentFunctions(db,"fn_legacy_payment_style_source_root_matches");
    }

    @AfterAll static void stop() { PG.stop(); }

    @BeforeEach void journals() {
        db.execute("TRUNCATE payment_styles,gl_entries,finance_report_line_bindings,finance_report_line_confirmations,fixed_assets,deferred_expenses,system_posting_style_roles");
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
        db.update("INSERT INTO gl_entries(voucher_id,style_id,direction,amount,entry_date,period) VALUES(gen_random_uuid(),?,1,10,DATE '2026-02-02','2026-02')",unknown);
        var incomplete=statements.profit(2026,2);
        amount(incomplete,32,"m1","200");
        assertThat(incomplete.stream().filter(row->row.get("lineNo").equals(32)).findFirst().orElseThrow().get("m2")).isNull();
    }

    private static UUID style(String category,String line) {
        UUID id=UUID.randomUUID();
        db.update("INSERT INTO payment_styles(id,code,name,category,level) VALUES(?,?,'同名科目',?,0)",id,"RANDOM-"+id,category);
        if(line!=null) db.update("INSERT INTO finance_report_line_bindings(line_key,binding_kind,style_id) VALUES(?,'STYLE',?)",line,id);
        return id;
    }

    private static void journal(String date,UUID debit,UUID credit,String amount) {
        UUID voucher=UUID.randomUUID();
        for(var entry:Map.of(debit,1,credit,-1).entrySet())
            db.update("INSERT INTO gl_entries(voucher_id,style_id,direction,amount,entry_date,period) VALUES(?,?,?,?::numeric,?::date,?)",
                    voucher,entry.getKey(),entry.getValue(),amount,date,date.substring(0,7));
    }

    private static void amount(java.util.List<Map<String,Object>> rows,int line,String key,String expected) {
        var row=rows.stream().filter(value->value.get("lineNo").equals(line)).findFirst().orElseThrow();
        assertThat((BigDecimal)row.get(key)).as("line %s %s",line,key).isEqualByComparingTo(expected);
    }

    private static Query query(String sql) {
        Map<String,Object> parameters=new LinkedHashMap<>();
        return mock(Query.class,call->{
            if(call.getMethod().getName().equals("setParameter")){parameters.put(call.getArgument(0),call.getArgument(1));return call.getMock();}
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
