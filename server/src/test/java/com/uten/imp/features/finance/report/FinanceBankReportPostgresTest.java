package com.uten.imp.features.finance.report;

import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.report.ReportReadPlan;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.asset.FixedAssetService;
import com.uten.imp.features.finance.cost.FinanceCostService;
import com.uten.imp.features.finance.gl.GlReportService;
import com.uten.imp.features.finance.statement.FinanceStatementService;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Independent decimal fixtures prove bank line/header grain, filters and exported workbook values. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinanceBankReportPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine")
            .withCreateContainerCmdModifier(cmd->cmd.getHostConfig().withMemory(512L*1024*1024).withNanoCPUs(1_000_000_000L));
    private static final LocalDate DATE=LocalDate.of(2026,11,1);
    private static JdbcTemplate db;
    private static NamedParameterJdbcTemplate named;
    private static FinanceReportService reports;
    private static FinanceDocumentAccessPolicy access;
    private static EntityManager em;
    private static final List<String> sqlRead=new ArrayList<>();
    private UUID currency,out,in,otherIn,transfer;

    @BeforeAll static void start() {
        PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(source);named=new NamedParameterJdbcTemplate(source);
        MigratedProjectionSchema.createCurrentTables(db,"finance_bank_transfers","finance_bank_transfer_lines","accounts","currencies");
        em=mock(EntityManager.class);when(em.createNativeQuery(anyString())).thenAnswer(call->query(call.getArgument(0)));
        access=mock(FinanceDocumentAccessPolicy.class);when(access.scope()).thenReturn(new OwnerScope(true,Set.of()));
        when(access.hasAuthority(anyString())).thenReturn(true);
        var settings=mock(SystemSettingsService.class);when(settings.readInt(any())).thenReturn(5000);
        reports=new FinanceReportService(em,access,settings,mock(FinanceStatementService.class),mock(FinanceCostService.class),
                mock(GlReportService.class),mock(FixedAssetService.class),mock(PartyMonthlySummaryService.class));
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void seed() {
        db.execute("TRUNCATE finance_bank_transfer_lines,finance_bank_transfers,accounts,currencies");
        currency=UUID.randomUUID();out=UUID.randomUUID();in=UUID.randomUUID();otherIn=UUID.randomUUID();transfer=UUID.randomUUID();
        db.update("INSERT INTO currencies(id,code,name) VALUES (?,'CNY','人民币')",currency);
        for(var account:Map.of(out,"取款账户",in,"收款甲",otherIn,"收款乙").entrySet())
            db.update("INSERT INTO accounts(id,name,currency_id) VALUES (?,?,?)",account.getKey(),account.getValue(),currency);
        header(transfer,"BANK-A",1,currency,"0.3003");
        line(transfer,in,1,"0.1001");line(transfer,otherIn,2,"0.2002");sqlRead.clear();
    }
    private void header(UUID id,String number,int status,UUID unit,String amount) {
        db.update("INSERT INTO finance_bank_transfers(id,bill_no,bill_date,status,currency_id,out_account_id,amount_original,amount_local,exchange_rate,remark) VALUES (?,?,?,?,?,?,CAST(? AS numeric),CAST(? AS numeric),1,'银行划转')",
                id,number,DATE,status,unit,out,amount,amount);
    }
    private void line(UUID id,UUID account,int ordinal,String amount) {
        db.update("INSERT INTO finance_bank_transfer_lines(id,transfer_id,bill_no,bill_date,in_account_id,line_no,amount_original,amount_local,summary) VALUES (gen_random_uuid(),?,'BANK-A',?,?,?,CAST(? AS numeric),CAST(? AS numeric),'分笔划转')",
                id,DATE,account,ordinal,amount,amount);
    }
    private static Query query(String sql) {
        Query q=mock(Query.class);Map<String,Object> p=new LinkedHashMap<>();
        when(q.setParameter(anyString(),any())).thenAnswer(call->{p.put(call.getArgument(0),call.getArgument(1));return q;});
        when(q.getResultList()).thenAnswer(call->{sqlRead.add(sql);return named.query(sql,p,(rs,n)->{
            Object[] row=new Object[rs.getMetaData().getColumnCount()];for(int i=0;i<row.length;i++)row[i]=rs.getObject(i+1);return row;});});
        when(q.getSingleResult()).thenAnswer(call->{sqlRead.add(sql);return named.queryForObject(sql,p,Long.class);});return q;
    }
    private ReportTableResponse report(String kind,UUID account,String keyword,Map<String,String> filters,int page,int size) {
        return reports.bankReport(kind,account,DATE,DATE,keyword,null,filters,page,size,null,null);
    }

    @ParameterizedTest @ValueSource(strings={"detail","summary"})
    void exactLineAndHeaderAmountsSurvivePaginationTotalsAndActualXlsx(String kind)throws Exception {
        int expected=kind.equals("detail")?2:1;
        var result=report(kind,out,null,Map.of(),1,1);
        assertThat(result.total()).isEqualTo(expected);
        assertThat(result.totals().stream().filter(t->t.key().equals("amountLocal")).findFirst().orElseThrow().groups().getFirst().value()).isEqualByComparingTo("0.3003");
        Map<String,String> params=Map.of("accountId",out.toString(),"dateFrom",DATE.toString(),"dateTo",DATE.toString());
        var payload=reports.export("bank/"+kind,params,null,null);
        assertThat(payload.rows()).hasSize(expected);
        assertThat(payload.rows().stream().map(row->(BigDecimal)row.get("amount")).reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo("0.3003");
        assertThat(payload.rows().stream().map(row->(BigDecimal)row.get("amountLocal")).reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo("0.3003");
        byte[] bytes=new XlsxExportService().build(payload.columns(),payload.rows());
        try(var workbook=new org.apache.poi.xssf.usermodel.XSSFWorkbook(new java.io.ByteArrayInputStream(bytes))) {
            var sheet=workbook.getSheetAt(0);assertThat(sheet.getLastRowNum()).isEqualTo(expected);
            int column=java.util.stream.IntStream.range(0,payload.columns().size()).filter(i->payload.columns().get(i).key().equals("amountLocal")).findFirst().orElseThrow();
            BigDecimal actual=BigDecimal.ZERO;
            for(int i=1;i<=expected;i++)actual=actual.add(BigDecimal.valueOf(sheet.getRow(i).getCell(column).getNumericCellValue()));
            assertThat(actual).isEqualByComparingTo("0.3003");
        }
    }
    @Test void selectedAccountDatesLiteralKeywordHeaderAndReversalFiltersHaveRealEffect() {
        var detail=report("detail",in,"BANK-A",Map.of(),1,50);
        assertThat(detail.rows()).singleElement().satisfies(row->assertThat((BigDecimal)row.get("amount")).isEqualByComparingTo("0.1001"));
        assertThat(report("summary",in,null,Map.of(),1,50).rows()).hasSize(1);
        assertThat(report("detail",UUID.randomUUID(),null,Map.of(),1,50).rows()).isEmpty();
        assertThat(report("detail",out,"missing",Map.of(),1,50).rows()).isEmpty();
        assertThat(reports.bankReport("detail",out,DATE.plusDays(1),DATE.plusDays(1),null,null,Map.of(),1,50,null,null).rows()).isEmpty();
        var header=report("detail",out,null,Map.of("search.amount",">0.15","currencyCode",currency.toString()),1,50);
        assertThat(header.rows()).singleElement().satisfies(row->assertThat((BigDecimal)row.get("amount")).isEqualByComparingTo("0.2002"));
        UUID reversed=UUID.randomUUID(),draft=UUID.randomUUID();header(reversed,"BANK-RED",-1,currency,"99");header(draft,"BANK-DRAFT",0,currency,"88");
        assertThat(report("summary",out,null,Map.of(),1,50).total()).isEqualTo(1);
        assertThat(report("summary",out,null,Map.of("status","已红冲"),1,50).rows()).singleElement().satisfies(row->assertThat(row.get("billNo")).isEqualTo("BANK-RED"));
        assertThat(report("summary",out,null,Map.of(),1,50).facets().get("status")).extracting(ReportFacet::label).contains("已审核","已红冲","草稿");
    }
    @Test void actualCurrencyIdentitiesPreventSameLabelOriginalAmountsBeingMerged() {
        UUID otherCurrency=UUID.randomUUID();db.update("INSERT INTO currencies(id,code,name) VALUES (?,'RMB','人民币')",otherCurrency);
        header(UUID.randomUUID(),"BANK-B",1,otherCurrency,"1.1111");
        var result=report("summary",out,null,Map.of(),1,50);
        assertThat(result.totals().stream().filter(t->t.key().equals("amount")).findFirst().orElseThrow().groups()).hasSize(2);
        assertThatThrownBy(()->report("summary",out,null,Map.of("search.amount",">0"),1,50)).isInstanceOf(com.uten.imp.common.web.ApiException.class);
    }
    @Test void deletedLinesCannotIncreaseDetailedAmountsOrMatchASelectedIncomingAccount() {
        UUID deletedAccount=UUID.randomUUID();db.update("INSERT INTO accounts(id,name,currency_id) VALUES (?,'已删明细账户',?)",deletedAccount,currency);
        line(transfer,deletedAccount,3,"999");db.update("UPDATE finance_bank_transfer_lines SET is_deleted=true WHERE in_account_id=?",deletedAccount);
        assertThat(report("detail",out,null,Map.of(),1,50).total()).isEqualTo(2);
        assertThat(report("detail",out,null,Map.of(),1,50).rows().stream().map(row->(BigDecimal)row.get("amount")).reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo("0.3003");
        assertThat(report("detail",deletedAccount,null,Map.of(),1,50).rows()).isEmpty();
        assertThat(report("summary",deletedAccount,null,Map.of(),1,50).rows()).isEmpty();
    }
    @Test void rowOnlyThousandLinePagingKeepsStableIdentityAndRunsNoCountOrFacetQueries() {
        db.update("DELETE FROM finance_bank_transfer_lines");
        db.update("INSERT INTO finance_bank_transfer_lines(id,transfer_id,bill_no,bill_date,in_account_id,line_no,amount_original,amount_local) SELECT md5('bank-line-'||n)::uuid,?,'BANK-A',?,?,n,n*.0001,n*.0001 FROM generate_series(1,1001)n",transfer,DATE,in);
        var result=new ArrayList<BigDecimal>();sqlRead.clear();
        try(var ignored=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)) {
            for(int page=1;page<=3;page++) {
                var batch=report("detail",out,null,Map.of(),page,400);assertThat(batch.total()).isEqualTo(-1);
                result.addAll(batch.rows().stream().map(row->(BigDecimal)row.get("amount")).toList());
            }
        }
        assertThat(result).hasSize(1001).doesNotHaveDuplicates();
        assertThat(result.getFirst()).isEqualByComparingTo(".0001");assertThat(result.getLast()).isEqualByComparingTo(".1001");
        assertThat(sqlRead).hasSize(3).allSatisfy(sql->assertThat(sql).contains("LIMIT :__limit OFFSET :__offset").doesNotContain("COUNT(*)"));
    }
}
