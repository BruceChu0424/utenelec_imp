package com.uten.imp.features.finance.report;

import com.uten.imp.features.finance.asset.FixedAssetService;
import com.uten.imp.features.finance.gl.GlReportService;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.FinanceReportTestAccess;
import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Real aggregate/book SQL over current schema shapes, with predicates before count and pagination. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class GlFaHeaderPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    private static JdbcTemplate db;private static NamedParameterJdbcTemplate named;
    private FixedAssetService assets;private GlReportService gl;
    @BeforeAll static void start(){
        PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(source);named=new NamedParameterJdbcTemplate(source);
        MigratedProjectionSchema.createCurrentTables(db,"payment_styles","gl_entries","gl_vouchers","fixed_assets","deferred_expenses",
                "fa_depreciation_log","da_amortization_log","departments","finance_asset_books","finance_asset_categories",
                "finance_deferral_schedule_versions","finance_deferral_schedule_lines","finance_asset_posting_runs","finance_asset_posting_lines",
                "finance_asset_template_metadata","finance_asset_opening_groups","finance_asset_opening_members","finance_asset_opening_entry_claims",
                "finance_asset_template_history","finance_template_sources","finance_gl_opening_baselines","finance_accounting_import_batches",
                "finance_gl_period_versions","finance_accounting_period_coverage","finance_gl_voucher_evidence","finance_chart_codes","finance_chart_code_styles");
        db.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto");
        MigratedProjectionSchema.createCurrentFunctions(db,"fn_finance_gl_voucher_is_booked","fn_finance_balance_asof_complete",
                "fn_finance_style_balance_asof","fn_finance_style_balance_evidence_fingerprint","fn_finance_asset_opening_group_valid");
        MigratedProjectionSchema.createCurrentViews(db,"v_finance_asset_posting_facts","v_finance_asset_report_facts");
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void fixture() throws Exception {
        db.execute("TRUNCATE payment_styles,gl_entries,gl_vouchers,fixed_assets,deferred_expenses,fa_depreciation_log,da_amortization_log,departments,finance_asset_books,finance_deferral_schedule_versions,finance_deferral_schedule_lines,finance_asset_posting_runs,finance_asset_posting_lines,finance_asset_template_metadata,finance_chart_codes,finance_chart_code_styles");
        var em=mock(EntityManager.class);when(em.createNativeQuery(anyString())).thenAnswer(call->query(call.getArgument(0)));
        var access=FinanceReportTestAccess.company();assets=new FixedAssetService(em,mock(TxSessionVars.class),access);
        var constructor=GlReportService.class.getConstructors()[0];
        gl=(GlReportService)constructor.newInstance(em,mock(constructor.getParameterTypes()[1]),access);
    }
    @Test void trialBalanceUsesCompletedOpeningAndDebitCreditRatherThanFilteringIndividualEntries(){
        LocalDate date=LocalDate.of(2026,10,10);
        for(int n=1;n<=3;n++){
            UUID style=UUID.randomUUID();db.update("INSERT INTO payment_styles(id,code,name,category,level) VALUES(?,?,?,'EXPENSE',2)",style,"GL-"+n,"科目%_"+n);
            for(var value:List.of(new Object[]{date.minusMonths(1),"10.0001",1},new Object[]{date,"7.0002",1},new Object[]{date,"2.0001",-1})) {
                UUID voucher=UUID.randomUUID();
                db.update("INSERT INTO gl_vouchers(id,voucher_no,voucher_date,status) VALUES(?,?,?,1)",voucher,voucher.toString(),value[0]);
                db.update("INSERT INTO gl_entries(voucher_id,style_id,direction,amount,entry_date,period) VALUES(?,?,?,?,?,?)",voucher,style,value[2],new BigDecimal(value[1].toString()),value[0],"2026-10");
            }
        }
        var options=new FinanceReportColumnOptions(Map.of("search.styleName","科目%_","search.closingDebit","15.0002..15.0002","search.debit",">=7.0002"),null,null);
        var first=gl.trialBalance(date.withDayOfMonth(1),date,1,1,options);var second=gl.trialBalance(date.withDayOfMonth(1),date,2,1,options);
        assertThat(first.total()).isEqualTo(3);assertThat(first.rows().getFirst()).containsEntry("styleCode","GL-1").containsEntry("closingDebitExact","15.0002");
        assertThat(second.rows().getFirst()).containsEntry("styleCode","GL-2");assertThat(first.columnSearchKeys()).contains("openingDebit","openingCredit","credit","closingDebit","closingCredit").doesNotContain("__styleId");
        assertThat(first.columns()).hasSize(9);
        assertThat(first.totals()).isEmpty();assertThat(second.totals()).isEmpty();
        var whole=gl.trialBalance(date.withDayOfMonth(1),date,1,100);
        var total=whole.rows().stream().filter(row->"TOTAL".equals(row.get("__rowKind"))).findFirst().orElseThrow();
        assertThat((BigDecimal)total.get("debit")).isEqualByComparingTo("21.0006");
        assertThat((BigDecimal)total.get("credit")).isEqualByComparingTo("6.0003");
        var located=gl.trialBalance(date.withDayOfMonth(1),date,1,1,new FinanceReportColumnOptions(Map.of("search.styleCode","GL-2"),null,null));
        assertThat(located.total()).isEqualTo(1);assertThat((BigDecimal)located.rows().getFirst().get("debit")).isEqualByComparingTo("7.0002");assertThat((BigDecimal)located.rows().getFirst().get("credit")).isEqualByComparingTo("2.0001");
        assertThat(gl.trialBalance(date.withDayOfMonth(1),date,4,1,options).rows()).isEmpty();
        assertThat(gl.trialBalance(date.withDayOfMonth(1),date,1,10,new FinanceReportColumnOptions(Map.of("search.styleName","科目X_"),null,null)).total()).isZero();
        assertThatThrownBy(()->gl.trialBalance(date.withDayOfMonth(1),date,1,10,
                new FinanceReportColumnOptions(Map.of(),"styleCode","desc")))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("保留结余顺序");
    }
    @Test void depreciationSearchesTheFullActiveBookAndPreservesOriginalValuesAndLocationFacets(){
        for(int n=1;n<=3;n++) {
            UUID asset=asset(false,n);postings(false,asset,n);
        }
        db.update("UPDATE fixed_assets SET status='停用' WHERE code='FA-2'");
        var options=new FinanceReportColumnOptions(Map.of("search.netValue","970.1231","search.monthlyDep","20.0002","search.accumDep",">=30.0003","location","部门%_"),"assetName","desc");
        var cutoff=LocalDate.of(2026,5,31);
        var first=assets.depreciationSchedule(1,1,options,cutoff);var second=assets.depreciationSchedule(2,1,options,cutoff);
        assertThat(first.total()).isEqualTo(2);
        assertThat(first.rows().getFirst()).containsEntry("assetName","资产%_2").containsEntry("accumDepExact","30.0003");
        assertThat(second.rows().getFirst()).containsEntry("assetName","资产%_1");
        assertThat(first.rows().getFirst().get("month202603")).isEqualTo(new BigDecimal("-999"));
        assertThat(first.rows().getFirst().get("month202604")).isEqualTo(new BigDecimal("999"));
        assertThat(first.rows().getFirst().get("month202605")).isNull();
        assertThat(first.totals()).isEmpty();assertThat(second.totals()).isEmpty();
        var filters=new LinkedHashMap<>(options.filters());filters.put("search.assetName","资产%_1");
        var narrow=assets.depreciationSchedule(1,1,new FinanceReportColumnOptions(filters,null,null),cutoff);
        assertThat(narrow.total()).isEqualTo(1);assertThat(narrow.rows().getFirst()).containsEntry("originalValueExact","1000.1234").containsEntry("netValueExact","970.1231");
        assertThat(first.facets().get("location").getFirst().count()).isEqualTo(2);
        assertThat(assets.depreciationSchedule(3,1,options,cutoff).rows()).isEmpty();
        var historical=assets.depreciationSchedule(1,10,FinanceReportColumnOptions.NONE,LocalDate.of(2026,2,28));
        assertThat(historical.total()).isEqualTo(3);
        assertThat(historical.rows()).allSatisfy(row->assertThat((BigDecimal)row.get("monthlyDep")).isEqualByComparingTo("20.0002"));
        assertThat(first.columnSearchKeys()).hasSize(55).contains("location","assetName","month202602").doesNotContain("__assetId","status","startPeriod");
        assertThatThrownBy(()->assets.depreciationSchedule(1,10,new FinanceReportColumnOptions(Map.of("search.postedMonths",">=2"),null,null),cutoff))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("postedMonths");
    }
    @Test void amortizationFiltersSignedCompletedHistoryBeforePagingAndKeepsUnpostedMonthsBlank(){
        for(int n=1;n<=3;n++){UUID deferred=asset(true,n);postings(true,deferred,n);}
        var cutoff=LocalDate.of(2026,5,31);
        var options=new FinanceReportColumnOptions(Map.of("search.remain","970.1231","search.accumAmt","30.0003","search.monthlyAmt","20.0002","search.assetName","待摊%_"),"assetName","asc");
        var result=assets.amortizationSchedule(2,1,options,cutoff);
        assertThat(result.total()).isEqualTo(2);assertThat(result.rows().getFirst()).containsEntry("assetName","待摊%_2").containsEntry("accumAmtExact","30.0003");
        assertThat(result.rows().getFirst()).containsEntry("month202603Exact","-999").containsEntry("month202604Exact","999");
        assertThat(result.rows().getFirst().get("month202605")).isNull();assertThat(result.totals()).isEmpty();
        var narrow=new LinkedHashMap<>(options.filters());narrow.put("search.assetName","待摊%_2");
        var single=assets.amortizationSchedule(1,1,new FinanceReportColumnOptions(narrow,null,null),cutoff);
        assertThat(single.total()).isEqualTo(1);assertThat(single.rows().getFirst()).containsEntry("totalAmountExact","1000.1234").containsEntry("remainExact","970.1231");
        assertThat(result.columnSearchKeys()).hasSize(42);
        assertThat(assets.amortizationSchedule(3,1,options,cutoff).rows()).isEmpty();
        assertThatThrownBy(()->assets.amortizationSchedule(1,10,new FinanceReportColumnOptions(Map.of("search.startPeriod","2026-01"),null,null),cutoff))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("startPeriod");
    }
    private UUID asset(boolean deferred,int number){
        UUID id=UUID.randomUUID();
        String table=deferred?"deferred_expenses":"fixed_assets";
        db.update("INSERT INTO "+table+"(id,code,name,"+(deferred?"total_amount,recognized_on":"original_value,capitalized_on")+",start_period,useful_months,lifecycle_status,is_deleted) VALUES(?,?,?,1000.1234,'2025-12-31','2026-01',10,'ACTIVE',false)",
                id,(deferred?"DA-":"FA-")+number,(deferred?"待摊%_":"资产%_")+number);
        db.update("UPDATE "+table+" SET "+(deferred?"service_start_on":"acquired_on")+"='2025-12-31' WHERE id=?",id);
        db.update("INSERT INTO finance_asset_template_metadata(object_type,object_id,valid_from,confirmed,source_reference,location_caption) VALUES(?,?,'2025-12-31',true,'fixture/source','部门%_')",deferred?"DEFERRED_EXPENSE":"FIXED_ASSET",id);
        if(deferred)db.update("INSERT INTO finance_deferral_schedule_versions(deferred_id,version,method,total_amount,useful_months,start_period,status,approved_at,nominal_monthly_amount,is_deleted) VALUES(?,1,'STRAIGHT_LINE',1000.1234,10,'2026-01','APPROVED','2025-12-31',20.0002,false)",id);
        else db.update("INSERT INTO finance_asset_books(asset_id,book_type,original_value,depreciable_amount,opening_accumulated_amount,useful_months,start_period,method,regular_monthly_amount,is_deleted) VALUES(?,'CORPORATE',1000.1234,1000.1234,0,10,'2026-01','STRAIGHT_LINE',20.0002,false)",id);
        return id;
    }
    private void postings(boolean deferred,UUID id,int number){
        posting(deferred,id,"2026-01","10.0001","NORMAL","ACTIVE");
        posting(deferred,id,"2026-02","20.0002","NORMAL","ACTIVE");
        // A reversal never erases the original. Their signed actual months both remain.
        posting(deferred,id,"2026-03","999","REVERSAL","ACTIVE");
        posting(deferred,id,"2026-04","999","NORMAL","REVERSED");
        if(number==3)posting(deferred,id,"2026-05","1","NORMAL","ACTIVE");
    }
    private void posting(boolean deferred,UUID id,String period,String amount,String kind,String status){
        UUID voucher=UUID.randomUUID(),run=UUID.randomUUID(),line=UUID.randomUUID();
        UUID book=deferred?null:db.queryForObject("SELECT id FROM finance_asset_books WHERE asset_id=?",UUID.class,id);
        LocalDate date=java.time.YearMonth.parse(period).atEndOfMonth();
        BigDecimal value=new BigDecimal(amount);
        db.update("INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type,status,is_deleted) VALUES(?,?,?,?,'AUTO',?,?,false)",voucher,voucher.toString(),period,date,deferred?"DA_AMT":"FA_DEP",status.equals("REVERSED")?-1:1);
        db.update("INSERT INTO finance_asset_posting_runs(id,book_type,status,voucher_id,is_deleted) VALUES(?,'CORPORATE',?,?,false)",run,status.equals("REVERSED")?"REVERSED":"POSTED",voucher);
        UUID expense=UUID.randomUUID();
        db.update("INSERT INTO finance_asset_posting_lines(id,run_id,fixed_asset_id,deferred_expense_id,asset_book_id,expense_style_id,line_kind,amount,voucher_id,is_deleted) VALUES(?,?,?,?,?,?,?,?,?,false)",line,run,deferred?null:id,deferred?id:null,book,expense,kind,value,voucher);
        String table=deferred?"da_amortization_log":"fa_depreciation_log",foreign=deferred?"deferred_id":"asset_id";
        List<Object> parameters=new ArrayList<>(List.of(id,period,value,kind,status,voucher,run,line));if(!deferred)parameters.add(book);
        db.update("INSERT INTO "+table+"("+foreign+",period,amount,entry_kind,status,voucher_id,posting_run_id,posting_line_id"+(deferred?"":",asset_book_id")+",is_deleted) VALUES(?,?,?,?,?,?,?,?"+(deferred?"":",?")+",false)",parameters.toArray());
        db.update("INSERT INTO gl_entries(voucher_id,style_id,direction,amount) VALUES(?,?,?,?)",voucher,expense,kind.equals("REVERSAL")?-1:1,value);
    }
    private Query query(String sql){Map<String,Object> parameters=new LinkedHashMap<>();return mock(Query.class,call->{
        String method=call.getMethod().getName();if(method.equals("setParameter")){parameters.put(call.getArgument(0),call.getArgument(1));return call.getMock();}
        if(method.equals("getSingleResult"))return named.queryForObject(sql,parameters,Object.class);
        if(method.equals("getResultList"))return named.query(sql,parameters,(rs,row)->{Object[] result=new Object[rs.getMetaData().getColumnCount()];for(int i=0;i<result.length;i++) { result[i]=rs.getObject(i+1); } return result;});
        if(Query.class.isAssignableFrom(call.getMethod().getReturnType()))return call.getMock();return org.mockito.Answers.RETURNS_DEFAULTS.answer(call);
    });}
}
