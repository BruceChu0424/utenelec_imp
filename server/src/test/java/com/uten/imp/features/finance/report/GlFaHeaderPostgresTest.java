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
        MigratedProjectionSchema.createCurrentTables(db,"payment_styles","gl_entries","fixed_assets","deferred_expenses","fa_depreciation_log","da_amortization_log","departments");
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void fixture() throws Exception {
        db.execute("TRUNCATE payment_styles,gl_entries,fixed_assets,deferred_expenses,fa_depreciation_log,da_amortization_log,departments");
        var em=mock(EntityManager.class);when(em.createNativeQuery(anyString())).thenAnswer(call->query(call.getArgument(0)));
        var access=FinanceReportTestAccess.company();assets=new FixedAssetService(em,mock(TxSessionVars.class),access);
        var constructor=GlReportService.class.getConstructors()[0];
        gl=(GlReportService)constructor.newInstance(em,mock(constructor.getParameterTypes()[1]),access);
    }
    @Test void trialBalanceUsesCompletedOpeningAndDebitCreditRatherThanFilteringIndividualEntries(){
        LocalDate date=LocalDate.of(2026,10,10);
        for(int n=1;n<=3;n++){
            UUID style=UUID.randomUUID();db.update("INSERT INTO payment_styles(id,code,name,category,level) VALUES(?,?,?,'EXPENSE',2)",style,"GL-"+n,"科目%_"+n);
            for(var value:List.of(new Object[]{date.minusMonths(1),"10.0001",1},new Object[]{date,"7.0002",1},new Object[]{date,"2.0001",-1}))
                db.update("INSERT INTO gl_entries(voucher_id,style_id,direction,amount,entry_date,period) VALUES(gen_random_uuid(),?,?,?,?,?)",style,value[2],new BigDecimal(value[1].toString()),value[0],"2026-10");
        }
        var options=new FinanceReportColumnOptions(Map.of("search.styleName","科目%_","search.closing","15.0002..15.0002","search.debit",">=7.0002"),"styleCode","desc");
        var first=gl.trialBalance(date.withDayOfMonth(1),date,1,1,options);var second=gl.trialBalance(date.withDayOfMonth(1),date,2,1,options);
        assertThat(first.total()).isEqualTo(3);assertThat(first.rows().getFirst()).containsEntry("styleCode","GL-3").containsEntry("closingExact","15.0002");
        assertThat(second.rows().getFirst()).containsEntry("styleCode","GL-2");assertThat(first.columnSearchKeys()).contains("opening","credit","closing").doesNotContain("__styleId");
        assertTotal(first,"debit","21.0006");assertTotal(first,"credit","6.0003");
        assertThat(first.totals()).isEqualTo(second.totals());
        assertThat(first.totals()).extracting(com.uten.imp.common.report.ReportTotal::key).containsExactly("debit","credit");
        var located=gl.trialBalance(date.withDayOfMonth(1),date,1,1,new FinanceReportColumnOptions(Map.of("search.styleCode","GL-2"),null,null));
        assertThat(located.total()).isEqualTo(1);assertTotal(located,"debit","7.0002");assertTotal(located,"credit","2.0001");
        assertThat(gl.trialBalance(date.withDayOfMonth(1),date,4,1,options).rows()).isEmpty();
        assertThat(gl.trialBalance(date.withDayOfMonth(1),date,1,10,new FinanceReportColumnOptions(Map.of("search.styleName","科目X_"),null,null)).total()).isZero();
    }
    @Test void depreciationSearchesTheFullActiveBookAndPreservesOriginalValuesAndDepartmentFacets(){
        UUID department=UUID.randomUUID();db.update("INSERT INTO departments(id,code,name) VALUES(?,'D','部门%_')",department);
        for(int n=1;n<=3;n++){
            UUID asset=UUID.randomUUID();db.update("INSERT INTO fixed_assets(id,code,name,department_id,original_value,salvage_rate,useful_months,start_period,status) VALUES(?,?,?, ?,1000.1234,.05,10,'2026-01','在用')",asset,"FA-"+n,"资产%_"+n,department);
            postings("fa_depreciation_log","asset_id",asset,n);
        }
        db.update("UPDATE fixed_assets SET status='停用' WHERE code='FA-2'");
        var options=new FinanceReportColumnOptions(Map.of("search.netValue","970.12","search.monthlyDep","95.01","search.postedMonths",">=2","dept","部门%_"),"code","desc");
        var first=assets.depreciationSchedule(1,1,options);var second=assets.depreciationSchedule(2,1,options);
        assertThat(first.total()).isEqualTo(2);assertThat(first.rows().getFirst()).containsEntry("code","FA-2").containsEntry("accumDepExact","30.0003");
        assertThat(first.rows().getFirst()).containsEntry("status","停用");
        assertTotal(first,"originalValue","2000.2468");assertTotal(first,"accumDep","60.0006");assertTotal(first,"netValue","1940.24");
        assertThat(first.totals()).isEqualTo(second.totals());
        assertThat(first.totals()).extracting(com.uten.imp.common.report.ReportTotal::key).containsExactly("originalValue","accumDep","netValue");
        var activeFilters=new LinkedHashMap<>(options.filters());activeFilters.put("status","在用");
        var active=assets.depreciationSchedule(1,1,new FinanceReportColumnOptions(activeFilters,null,null));
        assertThat(active.total()).isEqualTo(1);assertThat(active.rows().getFirst()).containsEntry("code","FA-1");
        assertTotal(active,"originalValue","1000.1234");assertTotal(active,"accumDep","30.0003");assertTotal(active,"netValue","970.12");
        assertThat(second.rows().getFirst()).containsEntry("code","FA-1");assertThat(first.facets().get("dept").getFirst().count()).isEqualTo(2);
        assertThat(assets.depreciationSchedule(3,1,options).rows()).isEmpty();
        assertThat(first.columnSearchKeys()).contains("salvageRate","startPeriod","status").doesNotContain("__assetId");
    }
    @Test void amortizationFiltersCompletedHistoryBeforePagingAndDoesNotCountReversals(){
        for(int n=1;n<=3;n++){
            UUID deferred=UUID.randomUUID();db.update("INSERT INTO deferred_expenses(id,code,name,total_amount,useful_months,start_period,status) VALUES(?,?,?,1000.1234,10,'2026-01','摊销中')",deferred,"DA-"+n,"待摊%_"+n);
            postings("da_amortization_log","deferred_id",deferred,n);
        }
        var options=new FinanceReportColumnOptions(Map.of("search.remain","970.12","search.accumAmt","30.0003","search.monthlyAmt","100.01","search.startPeriod","2026-01"),"code","asc");
        var result=assets.amortizationSchedule(2,1,options);assertThat(result.total()).isEqualTo(2);assertThat(result.rows().getFirst()).containsEntry("code","DA-2").containsEntry("postedMonths",2L).containsEntry("accumAmtExact","30.0003");
        assertTotal(result,"totalAmount","2000.2468");assertTotal(result,"accumAmt","60.0006");assertTotal(result,"remain","1940.24");
        assertThat(result.totals()).extracting(com.uten.imp.common.report.ReportTotal::key).containsExactly("totalAmount","accumAmt","remain");
        var narrow=new LinkedHashMap<>(options.filters());narrow.put("search.code","DA-2");
        var single=assets.amortizationSchedule(1,1,new FinanceReportColumnOptions(narrow,null,null));
        assertThat(single.total()).isEqualTo(1);assertTotal(single,"totalAmount","1000.1234");assertTotal(single,"accumAmt","30.0003");assertTotal(single,"remain","970.12");
        assertThat(result.columnSearchKeys()).hasSize(10);assertThat(assets.amortizationSchedule(3,1,options).rows()).isEmpty();
    }
    private static void assertTotal(ReportTableResponse response,String key,String expected) {
        var total=response.totals().stream().filter(value->value.key().equals(key)).findFirst().orElseThrow();
        assertThat(total.label()).startsWith("所列记录");assertThat(total.unitLabel()).isEqualTo("元");
        assertThat(total.groups()).hasSize(1);assertThat(total.groups().getFirst().value()).isEqualByComparingTo(expected);
    }
    private void postings(String table,String foreign,UUID id,int number){
        db.update("INSERT INTO "+table+"("+foreign+",period,amount,entry_kind,status) VALUES(?,'2026-01',10.0001,'NORMAL','ACTIVE'),(?,'2026-02',20.0002,'NORMAL','ACTIVE'),(?,'2026-03',999,'REVERSAL','ACTIVE'),(?,'2026-04',999,'NORMAL','REVERSED')",id,id,id,id);
        if(number==3)db.update("INSERT INTO "+table+"("+foreign+",period,amount,entry_kind,status) VALUES(?,'2026-05',1,'NORMAL','ACTIVE')",id);
    }
    private Query query(String sql){Map<String,Object> parameters=new LinkedHashMap<>();return mock(Query.class,call->{
        String method=call.getMethod().getName();if(method.equals("setParameter")){parameters.put(call.getArgument(0),call.getArgument(1));return call.getMock();}
        if(method.equals("getSingleResult"))return named.queryForObject(sql,parameters,Object.class);
        if(method.equals("getResultList"))return named.query(sql,parameters,(rs,row)->{Object[] result=new Object[rs.getMetaData().getColumnCount()];for(int i=0;i<result.length;i++)result[i]=rs.getObject(i+1);return result;});
        if(Query.class.isAssignableFrom(call.getMethod().getReturnType()))return call.getMock();return org.mockito.Answers.RETURNS_DEFAULTS.answer(call);
    });}
}
