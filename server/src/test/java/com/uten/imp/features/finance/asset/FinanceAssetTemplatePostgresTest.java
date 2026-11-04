package com.uten.imp.features.finance.asset;

import com.uten.imp.features.finance.*;
import com.uten.imp.features.finance.report.*;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.*;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.*;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

/** Migrated view + real PostgreSQL report SQL: reversal status must not erase history. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinanceAssetTemplatePostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    static JdbcTemplate db;static NamedParameterJdbcTemplate named;static FixedAssetService reports;
    static final UUID EXPENSE=UUID.randomUUID();
    @BeforeAll static void setup() {
        PG.start();var ds=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(ds);named=new NamedParameterJdbcTemplate(ds);
        MigratedProjectionSchema.createCurrentTables(db,"fixed_assets","deferred_expenses","finance_asset_books",
                "finance_asset_categories","finance_deferral_schedule_versions","finance_deferral_schedule_lines",
                "finance_asset_posting_runs","finance_asset_posting_lines","fa_depreciation_log","da_amortization_log",
                "gl_vouchers","gl_entries","finance_asset_template_metadata","finance_asset_opening_groups",
                "finance_asset_opening_members","finance_asset_opening_entry_claims","finance_asset_template_history","finance_template_sources",
                "payment_styles","finance_gl_opening_baselines","finance_accounting_import_batches","finance_gl_period_versions","finance_accounting_period_coverage","finance_gl_voucher_evidence");
        db.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto");
        MigratedProjectionSchema.createCurrentFunctions(db,"fn_finance_gl_voucher_is_booked","fn_finance_balance_asof_complete","fn_finance_style_balance_asof","fn_finance_style_balance_evidence_fingerprint","fn_finance_asset_opening_group_valid");
        MigratedProjectionSchema.createCurrentViews(db,"v_finance_asset_posting_facts","v_finance_asset_report_facts");
        EntityManager em=mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(c->query(c.getArgument(0)));
        var access=mock(FinanceDocumentAccessPolicy.class);
        when(access.hasAuthority(anyString())).thenReturn(true);when(access.scope()).thenReturn(new OwnerScope(true,Set.of()));
        reports=new FixedAssetService(em,mock(TxSessionVars.class),access);
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void clean(){db.execute("TRUNCATE fixed_assets,deferred_expenses,finance_asset_books,finance_asset_posting_runs,finance_asset_posting_lines,fa_depreciation_log,da_amortization_log,gl_vouchers,gl_entries,finance_asset_template_metadata");}

    @Test void originalReversalAndRepostRetainSignedMonthlyHistoryAndMatchGl() {
        UUID asset=asset(false),book=book(asset);
        UUID first=fact(asset,book,false,"2025-12", "25.1234","NORMAL","REVERSED",-1);
        fact(asset,book,false,"2025-12","25.1234","REVERSAL","ACTIVE",1);
        fact(asset,book,false,"2025-12","25.1235","NORMAL","ACTIVE",1);
        fact(asset,book,false,"2026-01","25.1234","NORMAL","ACTIVE",1);
        assertThat(db.queryForObject("SELECT count(*) FROM v_finance_asset_posting_facts WHERE NOT pending",Integer.class)).isEqualTo(4);
        var prior=reports.depreciationSchedule(1,50,FinanceReportColumnOptions.NONE,LocalDate.of(2025,12,31));
        assertThat(prior.columns()).hasSize(55);
        var row=prior.rows().getFirst();
        assertThat((BigDecimal)row.get("month202512")).isEqualByComparingTo("25.1235");
        assertThat(row.get("month202511")).isNull(); // unposted is not invented zero
        assertThat((BigDecimal)row.get("netValue")).isEqualByComparingTo("974.8765");
        assertThat(row.get("__pending")).isEqualTo(false);
        var now=reports.depreciationSchedule(1,50,FinanceReportColumnOptions.NONE,LocalDate.of(2026,1,31));
        assertThat((BigDecimal)now.rows().getFirst().get("accumDep")).isEqualByComparingTo("50.2469");
        BigDecimal gl=db.queryForObject("SELECT sum(e.direction*e.amount) FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id WHERE e.style_id=? AND v.voucher_date<='2026-01-31'",BigDecimal.class,EXPENSE);
        assertThat(gl).isEqualByComparingTo("50.2469");
        assertThat(db.queryForObject("SELECT amount_local FROM v_finance_asset_posting_facts WHERE fact_id=?",BigDecimal.class,first)).isEqualByComparingTo("25.1234");
    }
    @Test void missingPostingProofIsPendingRatherThanHealthyZeroAndDeferredNeverUsesFaFacts() {
        UUID asset=asset(false),book=book(asset),deferred=asset(true);
        fact(asset,book,false,"2026-01","8.0001","NORMAL","ACTIVE",1);
        fact(deferred,null,true,"2026-01","3.0002","NORMAL","ACTIVE",1);
        UUID schedule=UUID.randomUUID();
        db.update("INSERT INTO finance_deferral_schedule_versions(id,deferred_id,version,total_amount,useful_months,start_period,status,approved_at,is_deleted) VALUES(?,?,1,1000,12,'2026-01','APPROVED','2026-01-01',false)",schedule,deferred);
        db.update("INSERT INTO finance_deferral_schedule_lines(id,schedule_version_id,sequence,amount,is_deleted) VALUES(gen_random_uuid(),?,1,83.3333,false)",schedule);
        var report=reports.amortizationSchedule(1,50,FinanceReportColumnOptions.NONE,LocalDate.of(2026,1,31));
        assertThat(report.columns()).hasSize(42);
        assertThat((BigDecimal)report.rows().getFirst().get("month202601")).isEqualByComparingTo("3.0002");
        db.update("UPDATE finance_asset_posting_lines SET expense_style_id=NULL WHERE fixed_asset_id=?",asset);
        db.update("UPDATE fixed_assets SET expense_style_id=NULL,expense_style_snapshot_id=NULL WHERE id=?",asset);
        var unknown=reports.depreciationSchedule(1,50,FinanceReportColumnOptions.NONE,LocalDate.of(2026,1,31)).rows().getFirst();
        assertThat(unknown.get("__pending")).isEqualTo(true);assertThat(unknown.get("month202601")).isNull();assertThat(unknown.get("netValue")).isNull();
    }
    @Test void openingTotalDoesNotInventHistoricalMonthOrRange() {
        UUID asset=asset(false);book(asset);
        db.update("UPDATE fixed_assets SET opening_as_of='2025-12-31',opening_accumulated_amount=400 WHERE id=?",asset);
        db.update("UPDATE finance_asset_books SET opening_accumulated_amount=400 WHERE asset_id=?",asset);
        var row=reports.depreciationSchedule(1,50,FinanceReportColumnOptions.NONE,LocalDate.of(2026,1,31)).rows().getFirst();
        assertThat(row.get("month202512")).isNull();assertThat(row.get("accumDep")).isNull();
        assertThat((BigDecimal)row.get("netValue")).isEqualByComparingTo("600");
    }
    static UUID asset(boolean deferred) {
        UUID id=UUID.randomUUID();String table=deferred?"deferred_expenses":"fixed_assets";
        db.update("INSERT INTO "+table+"(id,code,name,"+(deferred?"total_amount,recognized_on":"original_value,capitalized_on")+",start_period,useful_months,lifecycle_status,expense_style_id,is_deleted) VALUES(?,?,?,1000,'2025-01-01','2025-12',12,'ACTIVE',?,false)",id,id.toString(),"匿名资产",EXPENSE);
        db.update("UPDATE "+table+" SET "+(deferred?"service_start_on":"acquired_on")+"='2025-01-01' WHERE id=?",id);
        db.update("INSERT INTO finance_asset_template_metadata(object_type,object_id,valid_from,confirmed,source_reference) VALUES(?,?,'2025-01-01',true,'匿名原表/A3')",deferred?"DEFERRED_EXPENSE":"FIXED_ASSET",id);
        return id;
    }
    static UUID book(UUID asset) {UUID book=UUID.randomUUID();db.update("INSERT INTO finance_asset_books(id,asset_id,book_type,original_value,depreciable_amount,opening_accumulated_amount,useful_months,start_period,method,is_deleted) VALUES(?,?,'CORPORATE',1000,1000,0,12,'2025-12','STRAIGHT_LINE',false)",book,asset);return book;}
    static UUID fact(UUID asset,UUID book,boolean deferred,String period,String amount,String kind,String status,int voucherStatus) {
        UUID log=UUID.randomUUID(),voucher=UUID.randomUUID(),run=UUID.randomUUID(),line=UUID.randomUUID();
        LocalDate date=java.time.YearMonth.parse(period).atEndOfMonth();BigDecimal value=new BigDecimal(amount);
        db.update("INSERT INTO gl_vouchers(id,voucher_no,voucher_date,status,is_deleted) VALUES(?,?,?,?,false)",voucher,voucher.toString(),date,voucherStatus);
        db.update("INSERT INTO finance_asset_posting_runs(id,book_type,status,voucher_id,is_deleted) VALUES(?,'CORPORATE',?,?,false)",run,status.equals("REVERSED")?"REVERSED":"POSTED",voucher);
        db.update("INSERT INTO finance_asset_posting_lines(id,run_id,fixed_asset_id,deferred_expense_id,asset_book_id,expense_style_id,line_kind,amount,voucher_id,is_deleted) VALUES(?,?,?,?,?,?,?,?,?,false)",line,run,deferred?null:asset,deferred?asset:null,book,EXPENSE,kind,value,voucher);
        db.update("INSERT INTO "+(deferred?"da_amortization_log":"fa_depreciation_log")+"(id,"+(deferred?"deferred_id":"asset_id")+",period,amount,entry_kind,status,voucher_id,posting_run_id,posting_line_id"+(deferred?"":",asset_book_id")+",is_deleted) VALUES(?,?,?,?,?,?,?,?,?"+(deferred?"":",?")+",false)",deferred?new Object[]{log,asset,period,value,kind,status,voucher,run,line}:new Object[]{log,asset,period,value,kind,status,voucher,run,line,book});
        db.update("INSERT INTO gl_entries(id,voucher_id,style_id,direction,amount) VALUES(gen_random_uuid(),?,?,1,?)",voucher,EXPENSE,kind.equals("REVERSAL")?value.negate():value);return log;
    }
    static Query query(String sql) {
        Query q=mock(Query.class);Map<String,Object> p=new LinkedHashMap<>();
        when(q.setParameter(anyString(),any())).thenAnswer(c->{p.put(c.getArgument(0),c.getArgument(1));return q;});
        when(q.getSingleResult()).thenAnswer(c->named.queryForObject(sql,p,Long.class));
        when(q.getResultList()).thenAnswer(c->named.query(sql,p,(r,n)->{Object[] row=new Object[r.getMetaData().getColumnCount()];for(int i=0;i<row.length;i++){row[i]=r.getObject(i+1);}return row;}));return q;
    }
}
