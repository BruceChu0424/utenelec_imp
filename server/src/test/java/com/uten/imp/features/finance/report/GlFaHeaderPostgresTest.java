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
        MigratedProjectionSchema.createCurrentTables(db,"payment_styles","gl_entries","gl_vouchers","fixed_assets","deferred_expenses","fa_depreciation_log","da_amortization_log","departments");
        com.uten.imp.support.FinanceReportProjectionSchema.assetReports(db);
        com.uten.imp.support.FinanceReportProjectionSchema.trialBalance(db);
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void fixture() throws Exception {
        db.execute("TRUNCATE payment_styles,gl_entries,gl_vouchers,fixed_assets,deferred_expenses,fa_depreciation_log,da_amortization_log,departments,finance_asset_books,finance_asset_categories,finance_deferral_schedule_versions,finance_deferral_schedule_lines,finance_asset_posting_runs,finance_asset_posting_lines,finance_asset_template_metadata,finance_asset_opening_groups,finance_asset_opening_members,finance_asset_opening_entry_claims,finance_asset_template_history,finance_template_sources,finance_gl_opening_baselines,finance_accounting_import_batches,finance_gl_period_versions,finance_accounting_period_coverage,finance_gl_voucher_evidence,finance_chart_codes,finance_chart_code_styles");
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
                db.update("INSERT INTO gl_vouchers(id,voucher_no,voucher_date,status,is_deleted) VALUES(?,?,?,1,false)",voucher,voucher.toString(),value[0]);
                db.update("INSERT INTO gl_entries(voucher_id,style_id,direction,amount,entry_date,period) VALUES(?,?,?,?,?,?)",voucher,style,value[2],new BigDecimal(value[1].toString()),value[0],"2026-10");
            }
        }
        var options=new FinanceReportColumnOptions(Map.of("search.styleName","科目%_","search.closingDebit","15.0002..15.0002","search.debit",">=7.0002"),null,null);
        var first=gl.trialBalance(date.withDayOfMonth(1),date,1,1,options);var second=gl.trialBalance(date.withDayOfMonth(1),date,2,1,options);
        assertThat(first.total()).isEqualTo(3);assertThat(first.rows().getFirst()).containsEntry("styleCode","GL-1").containsEntry("closingDebitExact","15.0002");
        assertThat(second.rows().getFirst()).containsEntry("styleCode","GL-2");
        assertThat(first.columnSearchKeys()).contains("openingDebit","openingCredit","credit","closingDebit","closingCredit").doesNotContain("__order","__styleId");
        assertThat(first.columns()).hasSize(9);
        var complete=gl.trialBalance(date.withDayOfMonth(1),date,1,50,options);
        assertSum(complete,"debit","21.0006");assertSum(complete,"credit","6.0003");
        assertThat(first.totals()).isEqualTo(second.totals());
        assertThat(first.totals()).isEmpty(); // Original subtotals are actual rows, not a second footer.
        assertThat(second.totals()).isEmpty();
        var whole=gl.trialBalance(date.withDayOfMonth(1),date,1,100);
        var total=whole.rows().stream().filter(row->"TOTAL".equals(row.get("__rowKind"))).findFirst().orElseThrow();
        assertThat((BigDecimal)total.get("debit")).isEqualByComparingTo("21.0006");
        assertThat((BigDecimal)total.get("credit")).isEqualByComparingTo("6.0003");
        var located=gl.trialBalance(date.withDayOfMonth(1),date,1,1,new FinanceReportColumnOptions(Map.of("search.styleCode","GL-2"),null,null));
        assertThat(located.total()).isEqualTo(1);assertThat((BigDecimal)located.rows().getFirst().get("debit")).isEqualByComparingTo("7.0002");assertThat((BigDecimal)located.rows().getFirst().get("credit")).isEqualByComparingTo("2.0001");
        assertSum(located,"debit","7.0002");assertSum(located,"credit","2.0001");
        assertThat(gl.trialBalance(date.withDayOfMonth(1),date,4,1,options).rows()).isEmpty();
        assertThat(gl.trialBalance(date.withDayOfMonth(1),date,1,10,new FinanceReportColumnOptions(Map.of("search.styleName","科目X_"),null,null)).total()).isZero();
        assertThatThrownBy(()->gl.trialBalance(date.withDayOfMonth(1),date,1,10,
                new FinanceReportColumnOptions(Map.of(),"styleCode","desc")))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("保留结余顺序");
    }
    @org.junit.jupiter.params.ParameterizedTest
    @org.junit.jupiter.params.provider.CsvSource({"20.0002,true","90.000123,false"})
    void depreciationSearchesTheFullActiveBookAndPreservesOriginalValuesAndLocationFacets(String nominal,boolean reversalFirst){
        UUID department=UUID.randomUUID();db.update("INSERT INTO departments(id,code,name) VALUES(?,'D','部门%_')",department);
        for(int n=1;n<=3;n++){UUID asset=asset(false,n,nominal,department);postings(false,asset,n,reversalFirst);}
        db.update("UPDATE fixed_assets SET status='停用' WHERE code='FA-2'");
        var options=new FinanceReportColumnOptions(Map.of("search.netValue","970.1231","search.monthlyDep",nominal,"search.accumDep",">=30.0003","location","部门%_"),"assetName","desc");
        var cutoff=LocalDate.of(2026,5,31);
        var first=assets.depreciationSchedule(1,1,options,cutoff);var second=assets.depreciationSchedule(2,1,options,cutoff);
        assertThat(first.total()).isEqualTo(2);
        assertThat(first.rows().getFirst()).containsEntry("assetName","资产%_2").containsEntry("accumDepExact","30.0003");
        assertThat(second.rows().getFirst()).containsEntry("assetName","资产%_1");
        assertThat((BigDecimal)first.rows().getFirst().get("monthlyDep")).isEqualByComparingTo(nominal);
        assertThat((BigDecimal)first.rows().getFirst().get("month202602")).isEqualByComparingTo("20.0002");
        assertThat(first.rows().getFirst().get("month202603")).isEqualTo(new BigDecimal(reversalFirst?"-999":"999"));
        assertThat(first.rows().getFirst().get("month202604")).isEqualTo(new BigDecimal(reversalFirst?"999":"-999"));
        assertThat(first.rows().getFirst().get("month202605")).isNull();
        var complete=assets.depreciationSchedule(1,50,options,cutoff);
        assertSum(complete,"originalValue","2000.2468");assertSum(complete,"accumDep","60.0006");assertSum(complete,"netValue","1940.2462");
        assertThat(first.totals()).isEqualTo(second.totals());assertThat(first.totals()).isEmpty();assertThat(second.totals()).isEmpty();
        var filters=new LinkedHashMap<>(options.filters());filters.put("search.assetName","资产%_1");
        var narrow=assets.depreciationSchedule(1,1,new FinanceReportColumnOptions(filters,null,null),cutoff);
        assertThat(narrow.total()).isEqualTo(1);assertThat(narrow.rows().getFirst()).containsEntry("assetName","资产%_1").containsEntry("originalValueExact","1000.1234").containsEntry("netValueExact","970.1231");
        assertSum(narrow,"originalValue","1000.1234");assertSum(narrow,"accumDep","30.0003");assertSum(narrow,"netValue","970.1231");
        assertThat(first.facets().get("location").getFirst().count()).isEqualTo(2);
        assertThat(assets.depreciationSchedule(3,1,options,cutoff).rows()).isEmpty();
        var historical=assets.depreciationSchedule(1,10,FinanceReportColumnOptions.NONE,LocalDate.of(2026,2,28));
        assertThat(historical.total()).isEqualTo(3);
        assertThat(historical.rows()).allSatisfy(row->{
            assertThat((BigDecimal)row.get("monthlyDep")).isEqualByComparingTo(nominal);
            assertThat((BigDecimal)row.get("month202602")).isEqualByComparingTo("20.0002");
        });
        assertThat(first.columnSearchKeys()).hasSize(55).contains("location","acquiredOn","assetName","month202602").doesNotContain("__assetId","status","startPeriod");
        assertThatThrownBy(()->assets.depreciationSchedule(1,10,new FinanceReportColumnOptions(Map.of("search.postedMonths",">=2"),null,null),cutoff))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("postedMonths");
    }
    @org.junit.jupiter.params.ParameterizedTest
    @org.junit.jupiter.params.provider.CsvSource({"20.0002,true","90.000123,false"})
    void amortizationFiltersSignedCompletedHistoryBeforePagingAndKeepsUnpostedMonthsBlank(String nominal,boolean reversalFirst){
        for(int n=1;n<=3;n++){UUID deferred=asset(true,n,nominal,null);postings(true,deferred,n,reversalFirst);}
        var cutoff=LocalDate.of(2026,5,31);
        var options=new FinanceReportColumnOptions(Map.of("search.remain","970.1231","search.accumAmt","30.0003","search.monthlyAmt",nominal,"search.month202602","20.0002","search.assetName","待摊%_"),"assetName","asc");
        var result=assets.amortizationSchedule(2,1,options,cutoff);
        assertThat(result.total()).isEqualTo(2);assertThat(result.rows().getFirst()).containsEntry("assetName","待摊%_2").containsEntry("accumAmtExact","30.0003");
        assertThat((BigDecimal)result.rows().getFirst().get("monthlyAmt")).isEqualByComparingTo(nominal);
        assertThat(result.rows().getFirst()).containsEntry("month202603Exact",reversalFirst?"-999":"999").containsEntry("month202604Exact",reversalFirst?"999":"-999");
        assertThat(result.rows().getFirst().get("month202605")).isNull();assertThat(result.totals()).isEmpty();
        var complete=assets.amortizationSchedule(1,50,options,cutoff);
        assertSum(complete,"totalAmount","2000.2468");assertSum(complete,"accumAmt","60.0006");assertSum(complete,"remain","1940.2462");
        var narrow=new LinkedHashMap<>(options.filters());narrow.put("search.assetName","待摊%_2");
        var single=assets.amortizationSchedule(1,1,new FinanceReportColumnOptions(narrow,null,null),cutoff);
        assertThat(single.total()).isEqualTo(1);assertThat(single.rows().getFirst()).containsEntry("totalAmountExact","1000.1234").containsEntry("remainExact","970.1231");
        assertSum(single,"totalAmount","1000.1234");assertSum(single,"accumAmt","30.0003");assertSum(single,"remain","970.1231");
        assertThat(result.columns()).hasSize(42);assertThat(result.columnSearchKeys()).hasSize(42);
        assertThat(assets.amortizationSchedule(3,1,options,cutoff).rows()).isEmpty();
        assertThatThrownBy(()->assets.amortizationSchedule(1,10,new FinanceReportColumnOptions(Map.of("search.startPeriod","2026-01"),null,null),cutoff))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("startPeriod");
    }
    private static void assertSum(ReportTableResponse response,String key,String expected){
        assertThat(response.rows().stream().filter(row->row.get("__rowKind")==null||"DETAIL".equals(row.get("__rowKind")))
                .map(row->(BigDecimal)row.get(key)).reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo(expected);
    }
    private UUID asset(boolean deferred,int number,String nominal,UUID department){
        UUID id=UUID.randomUUID();String table=deferred?"deferred_expenses":"fixed_assets";
        db.update("INSERT INTO "+table+"(id,code,name,department_id,"+(deferred?"total_amount,recognized_on":"original_value,capitalized_on")+",start_period,useful_months,status,lifecycle_status,is_deleted) VALUES(?,?,?,?,1000.1234,DATE '2025-12-31','2026-01',10,?,'ACTIVE',false)",
                id,(deferred?"DA-":"FA-")+number,(deferred?"待摊%_":"资产%_")+number,department,deferred?"摊销中":"在用");
        if(!deferred)db.update("UPDATE fixed_assets SET salvage_rate=.05 WHERE id=?",id);
        com.uten.imp.support.FinanceAssetProjectionFacts.freeze(db,deferred,id,nominal,LocalDate.of(2025,12,31));
        db.update("UPDATE finance_asset_template_metadata SET location_caption='部门%_' WHERE object_id=?",id);
        return id;
    }
    private void postings(boolean deferred,UUID id,int number,boolean reversalFirst){
        com.uten.imp.support.FinanceAssetProjectionFacts.post(db,deferred,id,"2026-01","10.0001","NORMAL","ACTIVE",LocalDate.of(2026,1,31),false);
        com.uten.imp.support.FinanceAssetProjectionFacts.post(db,deferred,id,"2026-02","20.0002","NORMAL","ACTIVE",LocalDate.of(2026,2,28),false);
        // Both originals and reversals remain signed actual facts. Exercise
        // Main's order and the earlier opposite ordering as independent fixtures.
        com.uten.imp.support.FinanceAssetProjectionFacts.post(db,deferred,id,"2026-03","999",reversalFirst?"REVERSAL":"NORMAL",reversalFirst?"ACTIVE":"REVERSED",LocalDate.of(2026,3,31),false);
        com.uten.imp.support.FinanceAssetProjectionFacts.post(db,deferred,id,"2026-04","999",reversalFirst?"NORMAL":"REVERSAL",reversalFirst?"REVERSED":"ACTIVE",LocalDate.of(2026,4,30),false);
        if(number==3)com.uten.imp.support.FinanceAssetProjectionFacts.post(db,deferred,id,"2026-05","1","NORMAL","ACTIVE",LocalDate.of(2026,5,31),false);
    }
    private Query query(String sql){Map<String,Object> parameters=new LinkedHashMap<>();return mock(Query.class,call->{
        String method=call.getMethod().getName();if(method.equals("setParameter")){parameters.put(call.getArgument(0),call.getArgument(1));return call.getMock();}
        if(method.equals("getSingleResult"))return named.queryForObject(sql,parameters,Object.class);
        if(method.equals("getResultList"))return named.query(sql,parameters,(rs,row)->{Object[] result=new Object[rs.getMetaData().getColumnCount()];for(int i=0;i<result.length;i++) { result[i]=rs.getObject(i+1); } return result;});
        if(Query.class.isAssignableFrom(call.getMethod().getReturnType()))return call.getMock();return org.mockito.Answers.RETURNS_DEFAULTS.answer(call);
    });}
}
