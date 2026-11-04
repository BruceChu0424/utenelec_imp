package com.uten.imp.features.finance.gl;

import com.uten.imp.features.finance.report.FinanceReportColumnOptions;
import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.anyString;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinanceTrialBalancePostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    private static JdbcTemplate db;private static NamedParameterJdbcTemplate named;
    private static final LocalDate FROM=LocalDate.of(2026,1,1),TO=LocalDate.of(2026,1,31);
    @BeforeAll static void start(){
        PG.start();var data=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(data);named=new NamedParameterJdbcTemplate(data);
        MigratedProjectionSchema.createCurrentTables(db,"payment_styles","gl_entries","gl_vouchers","finance_chart_codes","finance_chart_code_styles",
                "finance_gl_period_versions","finance_accounting_period_coverage","finance_accounting_import_batches","finance_gl_opening_baselines","finance_gl_voucher_evidence");
        MigratedProjectionSchema.createCurrentFunctions(db,"fn_finance_gl_voucher_is_booked","fn_finance_balance_asof_complete");
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void reset(){db.execute("TRUNCATE finance_chart_code_styles,finance_chart_codes,gl_entries,gl_vouchers,payment_styles,finance_gl_period_versions,finance_accounting_period_coverage,finance_accounting_import_batches,finance_gl_opening_baselines,finance_gl_voucher_evidence");}
    @Test void sourceUuidMappingGroupsOnceAndSignedOpeningClosingUseTrueDebitCreditDirections(){
        UUID cash=style("ACCOUNT"),cash2=style("ACCOUNT"),capital=style("EQUITY");
        code("1001","库存现金","",1,cash,cash2);code("3001","实收资本","",2,capital);
        entry(cash,1,"1000","2025-12-31");entry(capital,-1,"1000","2025-12-31");
        entry(cash,-1,"200.0001","2026-01-10");entry(cash2,1,"50.0001","2026-01-10");
        entry(cash,1,"9999","2026-02-01"); // a future-only movement must not enter January
        var rows=named.queryForList(FinanceTrialBalance.sql(),Map.of("from",FROM,"to",TO));
        assertThat(rows).hasSize(2);var money=find(rows,"1001");
        amount(money,"openingDebit","1000");amount(money,"openingCredit","0");
        amount(money,"debit","50.0001");amount(money,"credit","200.0001");amount(money,"closingDebit","850");
        amount(find(rows,"3001"),"openingCredit","1000");amount(find(rows,"3001"),"closingCredit","1000");
        assertThat(FinanceTrialBalance.columns()).extracting(c->c.label()).containsExactly("科目编码","科目名称","外币名称",
                "期初借方","期初贷方","本期发生借方","本期发生贷方","期末借方","期末贷方");
    }
    @Test void currencyNameIsAnAccountAttributeAndNineAmountColumnsStayLocalWhileUnmappedCodesRemainUnknown(){
        UUID local=style("ACCOUNT"),foreign=style("ACCOUNT");
        code("1001","现金","",1,local);code("112202","美元应收","美元",2,foreign);code("1601","固定资产","",3);
        entry(local,1,"10","2026-01-10");entry(foreign,1,"700","2026-01-10");
        var report=FinanceTrialBalance.read(entityManager(),FROM,TO,1,1,FinanceReportColumnOptions.NONE);
        assertThat(report.total()).isGreaterThan(3);assertThat(report.rows()).hasSize(1);
        assertThat(report.totals()).isEmpty(); // body totals must not be summed a second time
        var rows=named.queryForList(FinanceTrialBalance.sql(),Map.of("from",FROM,"to",TO));
        amount(find(rows,"112202"),"debit","700");
        assertThat(find(rows,"112202")).containsEntry("currencyName","美元").containsEntry("__pending",false);
        assertThat(find(rows,"1601")).containsEntry("openingDebit",null).containsEntry("closingDebit",null);
        assertThat(find(rows,"1001")).containsEntry("__pending",false);
    }
    @Test void originalFiveClassSubtotalsAndCurrencyRowsKeepExactCellPositionsAndNeverCountSubtotalsTwice(){
        UUID cash=style("ACCOUNT"),dollars=style("ACCOUNT"),debt=style("LIABILITY"),equity=style("EQUITY"),cost=style("ACCOUNT"),income=style("INCOME");
        code("1001","库存现金","",1,cash);code("112202","应收美元","美元",2,dollars);code("2202","应付","",3,debt);
        code("3001","资本","",4,equity);code("4001","生产成本","",5,cost);code("5001","主营收入","",6,income);
        db.update("UPDATE finance_chart_codes SET classification=CASE WHEN code IN('1001','112202') THEN 'ASSET' WHEN code='2202' THEN 'LIABILITY' WHEN code='3001' THEN 'EQUITY' WHEN code='4001' THEN 'COST' ELSE 'PROFIT' END");
        entry(cash,1,"12.3456","2026-01-03");entry(dollars,1,"7.0001","2026-01-04");entry(debt,-1,"3.5","2026-01-05");
        entry(equity,-1,"2","2026-01-06");entry(cost,1,"1.25","2026-01-07");entry(income,-1,"15.0957","2026-01-08");
        var report=FinanceTrialBalance.read(entityManager(),FROM,TO,1,500,FinanceReportColumnOptions.NONE);
        assertThat(report.rows()).extracting(r->r.get("styleName")).containsExactly("库存现金","应收美元","资产小计","美元","应付","负债小计","资本","权益小计","生产成本","成本小计","主营收入","损益小计","合计","美元");
        var detail=find(report.rows(),"1001");amount(detail,"openingDebit","0");amount(detail,"debit","12.3456");amount(detail,"closingDebit","12.3456");
        assertThat(detail).containsEntry("__pending",false).containsEntry("__order",1);
        var total=report.rows().stream().filter(r->"TOTAL".equals(r.get("__rowKind"))).findFirst().orElseThrow();
        amount(total,"debit","20.5957");amount(total,"credit","20.5957");
        assertThat(report.rows().stream().filter(r->"CURRENCY".equals(r.get("__rowKind"))))
                .hasSize(2).allSatisfy(r->amount(r,"debit","7.0001"));
        db.update("DELETE FROM finance_chart_code_styles WHERE code='112202'");
        var pending=FinanceTrialBalance.read(entityManager(),FROM,TO,1,500,FinanceReportColumnOptions.NONE);
        var assetTotal=pending.rows().stream().filter(r->"资产小计".equals(r.get("styleName"))).findFirst().orElseThrow();
        assertThat(assetTotal).containsEntry("debit",null).containsEntry("__pending",true);
    }
    @Test void duplicateClaimOfOneSourceUuidIsRejectedByTheDatabase(){
        UUID source=style("ACCOUNT");code("1001","现金","",1,source);code("100201","公账","",2);
        assertThatThrownBy(()->db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by) VALUES('100201',?,gen_random_uuid())",source))
                .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
    }
    @Test void nativeBookZeroIsReadableButAnExplicitLaterExternalStartDoesNotInventEarlierHistory(){
        UUID cash=style("ACCOUNT");code("1001","库存现金","",1,cash);
        var nativeBook=FinanceTrialBalance.read(entityManager(),FROM,TO,1,50,FinanceReportColumnOptions.NONE).rows().getFirst();
        amount(nativeBook,"debit","0");amount(nativeBook,"openingDebit","0");amount(nativeBook,"closingDebit","0");
        UUID source=UUID.randomUUID();
        db.update("INSERT INTO finance_accounting_import_batches(id,actor_id,source_name,storage_provider,storage_key,storage_size,sha256,source_system,preview,status,result) VALUES(?,gen_random_uuid(),'anonymous.xls','test','test',1,repeat('0',64),'TEST','{}','POSTED','{}')",source);
        db.update("INSERT INTO finance_gl_opening_baselines(effective_from,import_batch_id,source_sha256,verified_by) VALUES(DATE '2026-03-01',?,repeat('0',64),gen_random_uuid())",source);
        db.execute("INSERT INTO finance_gl_period_versions(period) VALUES('2026-01')");
        db.execute("INSERT INTO finance_accounting_period_coverage(period,entries_revision,source_kind,source_sha256,verified_by) VALUES('2026-01',0,'EXPLICIT_REVIEWED_ZERO',repeat('0',64),gen_random_uuid())");
        var missingHistory=FinanceTrialBalance.read(entityManager(),FROM,TO,1,50,FinanceReportColumnOptions.NONE).rows().getFirst();
        assertThat(missingHistory).containsEntry("debit",null).containsEntry("openingDebit",null).containsEntry("closingDebit",null).containsEntry("__pending",true);
    }
    private static UUID style(String category){UUID id=UUID.randomUUID();db.update("INSERT INTO payment_styles(id,code,name,category,level) VALUES(?,?,?, ?,0)",id,"S-"+id,"同名",category);return id;}
    private static void code(String code,String name,String currency,int order,UUID...styles){
        db.update("INSERT INTO finance_chart_codes(code,name,currency_name,sort_order,source_row,source_import_id,updated_by) VALUES(?,?,?,?,1,gen_random_uuid(),gen_random_uuid())",code,name,currency,order);
        for(UUID style:styles)db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by) VALUES(?,?,gen_random_uuid())",code,style);
    }
    private static void entry(UUID style,int direction,String amount,String date){UUID voucher=UUID.randomUUID();db.update("INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type) VALUES(?,?,?,?::date,'MANUAL','ANONYMOUS')",voucher,voucher.toString(),date.substring(0,7),date);db.update("INSERT INTO gl_entries(voucher_id,style_id,direction,amount,entry_date,period) VALUES(?,?,?,?::numeric,?::date,?)",voucher,style,direction,amount,date,date.substring(0,7));}
    private static Map<String,Object> find(List<Map<String,Object>> rows,String code){return rows.stream().filter(r->code.equals(r.get("styleCode"))).findFirst().orElseThrow();}
    private static void amount(Map<String,Object> row,String key,String value){assertThat((BigDecimal)row.get(key)).as(key).isEqualByComparingTo(value);}
    private static EntityManager entityManager(){
        var em=mock(EntityManager.class);when(em.createNativeQuery(anyString())).thenAnswer(call->{
            String sql=call.getArgument(0);Map<String,Object> args=new HashMap<>();
            return mock(Query.class,q->{
                if(q.getMethod().getName().equals("setParameter")){args.put(q.getArgument(0),q.getArgument(1));return q.getMock();}
                if(q.getMethod().getName().equals("getSingleResult"))return named.queryForObject(sql,args,Object.class);
                if(q.getMethod().getName().equals("getResultList"))return named.query(sql,args,(rs,n)->{
                    if(rs.getMetaData().getColumnCount()==1)return rs.getObject(1);
                    Object[] row=new Object[rs.getMetaData().getColumnCount()];for(int i=0;i<row.length;i++)row[i]=rs.getObject(i+1);return row;
                });
                return org.mockito.Answers.RETURNS_DEFAULTS.answer(q);
            });
        });return em;
    }
}
