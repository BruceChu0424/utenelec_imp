package com.uten.imp.features.finance.report;

import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.common.report.ReportReadPlan;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.asset.FixedAssetService;
import com.uten.imp.features.finance.cost.FinanceCostService;
import com.uten.imp.features.finance.gl.GlReportService;
import com.uten.imp.features.finance.statement.FinanceStatementService;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Query projections retain decimal facts and distinguish document, ledger and account currencies. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinanceReportUnitsPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine")
            .withCreateContainerCmdModifier(cmd->cmd.getHostConfig().withMemory(768L*1024*1024).withNanoCPUs(1_000_000_000L));
    private static final UUID CLIENT=UUID.randomUUID(),SUPPLIER=UUID.randomUUID(),CURRENCY=UUID.randomUUID(),ACCOUNT=UUID.randomUUID();
    private static final LocalDate DATE=LocalDate.of(2026,10,12);
    private static JdbcTemplate db;
    private static NamedParameterJdbcTemplate named;
    private static EntityManager em;
    private static FinanceReportService reports;
    private static FinanceDocumentAccessPolicy access;
    private static SystemSettingsService settings;
    private static List<String> dataColumns=List.of();
    private static final List<String> executedSql = new java.util.ArrayList<>();

    @BeforeAll static void start(){
        PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(source);named=new NamedParameterJdbcTemplate(source);
        MigratedProjectionSchema.createCurrentTables(db,"finance_receipts","finance_receipt_lines","finance_payments",
                "finance_expenses","finance_expense_items","finance_other_incomes","finance_other_income_items",
                "finance_reconciliations","account_flow_monthly_summaries","ar_ap_ledger","ar_ap_source_refs","accounts","clients","suppliers",
                "currencies","employees","departments","payment_styles","client_director_v","client_categories","supplier_categories","sales_orders",
                "sales_order_items","sales_shipments","sales_shipment_items","customer_open_item_offset_batches","customer_open_item_offsets",
                "fixed_assets","deferred_expenses","fa_depreciation_log","da_amortization_log","gl_entries",
                "goods","material_categories","v_stock_actual_cogs_postings","units","colors",
                "purchase_receipts","purchase_receipt_items","purchase_returns","purchase_return_items","sales_returns","sales_return_items",
                "party_monthly_summaries","finance_payment_lines","supplier_open_item_offsets","legacy_finance_import_sources");
        em=mock(EntityManager.class);when(em.createNativeQuery(anyString())).thenAnswer(call->query(call.getArgument(0)));
        access=mock(FinanceDocumentAccessPolicy.class);when(access.scope()).thenReturn(new OwnerScope(true,Set.of()));
        when(access.hasAuthority(anyString())).thenReturn(true);
        when(access.nativeReadScope(anyString(),anyString(),any(OwnerScope.class))).thenReturn(new NativeReadScope("1=1",null,Set.of()));
        settings=mock(SystemSettingsService.class);when(settings.readInt(any())).thenReturn(500);
        reports=new FinanceReportService(em,access,settings,mock(FinanceStatementService.class),
                mock(FinanceCostService.class),mock(GlReportService.class),mock(FixedAssetService.class),
                mock(PartyMonthlySummaryService.class));
        db.update("INSERT INTO currencies(id,name,code) VALUES (?,'美金','002')",CURRENCY);
        db.update("INSERT INTO clients(id,code,name) VALUES (?,'CLIENT','客户名')",CLIENT);
        db.update("INSERT INTO suppliers(id,code,name) VALUES (?,'SUPPLIER','供应商名')",SUPPLIER);
        db.update("INSERT INTO accounts(id,name,currency_id,init_balance) VALUES (?,'美元账户',?,3)",ACCOUNT,CURRENCY);
    }
    @AfterAll static void stop(){PG.stop();}

    @Test void overviewHeadersApplyToCompletePartyAggregatesAndTheSameExportAndTotals() {
        db.update("UPDATE clients SET phone='020-12345678',address='华南 工业园' WHERE id=?",CLIENT);
        for (int amount : new int[]{10,20}) db.update("""
                INSERT INTO ar_ap_ledger(id,client_id,direction,status,bill_no,bill_date,source_doc_type,
                    amount_original,amount_original_local,amount_balance,currency_id,is_deleted)
                VALUES(gen_random_uuid(),?,'AR',1,?,?, 'SALES_SHIPMENT',?,?,?, ?,false)
                """,CLIENT,"Z-"+amount,DATE,amount,amount,amount,CURRENCY);
        var filters=Map.of("search.partyName","客户 名","partyType","客户","search.receivable",">=25",
                "search.phone","1234 5678","search.address","华南 工业园");
        var first=reports.arApOverview(DATE,DATE,"ALL",null,null,null,1,1,filters,"receivable","desc");
        assertThat(first.total()).isEqualTo(1);
        assertThat(first.rows()).singleElement().satisfies(row-> {
            assertThat(row.get("partyName")).isEqualTo("客户名");
            assertThat((BigDecimal)row.get("receivable")).isEqualByComparingTo("30");
        });
        assertThat(first.columnSearchKeys()).containsExactlyInAnyOrder("partyName","partyType","phone","address","receivable","payable");
        assertThat(first.totals()).anySatisfy(total->{
            assertThat(total.key()).isEqualTo("receivable");
            assertThat(total.groups().getFirst().value()).isEqualByComparingTo("30");
        });
        assertThat(reports.arApOverview(DATE,DATE,"ALL",null,null,null,2,1,filters,"receivable","desc").rows()).isEmpty();
        Map<String,String> parameters=new LinkedHashMap<>();
        filters.forEach((key,value)->parameters.put("f."+key,value));
        parameters.put("dateFrom",DATE.toString());parameters.put("dateTo",DATE.toString());
        var exported=reports.export("ar-ap/overview",parameters,"receivable","desc");
        assertThat(exported.rows()).hasSize(1);
        assertThat((BigDecimal)exported.rows().getFirst().get("receivable")).isEqualByComparingTo("30");
    }

    @Test void partyHeadersKeepFullChronologicalCurrencyBalancesBeforeFilterCountFacetsAndExport() {
        UUID secondCurrency=UUID.randomUUID();
        db.update("INSERT INTO currencies(id,name,code) VALUES(?,'另币','OTHER')",secondCurrency);
        for (Object[] fact : List.of(new Object[]{"PRIOR",CURRENCY,100,700,"2026-10-01"},
                new Object[]{"OTHER",secondCurrency,5,35,"2026-10-02"},
                new Object[]{"LATER",CURRENCY,5,35,"2026-10-15"})) {
            db.update("""
                    INSERT INTO ar_ap_ledger(id,client_id,direction,status,bill_no,bill_date,source_doc_type,
                        amount_original,amount_original_local,amount_balance,currency_id,is_deleted,exchange_rate)
                    VALUES(gen_random_uuid(),?,'AR',1,?,CAST(? AS date),'SALES_SHIPMENT',?,?,?, ?,false,7)
                    """,CLIENT,fact[0],fact[4],fact[2],fact[3],fact[3],fact[1]);
        }
        db.update("""
                INSERT INTO finance_receipts(id,bill_no,bill_date,status,currency_id,client_id,amount_original,
                    amount_local,exchange_rate,remark,is_deleted)
                VALUES(gen_random_uuid(),'TARGET-CASH',?,1,?,?,30,210,7,'原始收款事实',false)
                """,DATE,CURRENCY,CLIENT);
        LocalDate from=LocalDate.of(2026,10,1),to=LocalDate.of(2026,10,31);
        var filters=Map.of("currencyCode",CURRENCY.toString(),"search.refNo","TARGET CASH",
                "search.billDate","2026-10-12","search.balanceOriginal","70",
                "search.balanceLocal","525","search.receiptOriginal",">=30","type","冲减应收");
        var result=reports.partyStatementDetail(CLIENT,"AR",from,to,1,1,filters,"balanceOriginal","desc");
        assertThat(result.total()).isEqualTo(1);
        assertThat(result.rows()).singleElement().satisfies(row->{
            assertThat(row.get("refNo")).isEqualTo("TARGET-CASH");
            assertThat((BigDecimal)row.get("balanceOriginal")).isEqualByComparingTo("70");
            assertThat((BigDecimal)row.get("balanceLocal")).isEqualByComparingTo("525");
        });
        assertThat(result.facets().get("currencyCode")).extracting(ReportFacet::value).contains(CURRENCY.toString());
        assertThat(result.totals()).noneMatch(total->total.key().startsWith("balance"));
        assertThat(result.totals()).anySatisfy(total->{
            assertThat(total.key()).isEqualTo("receiptLocal");
            assertThat(total.groups().getFirst().value()).isEqualByComparingTo("210");
        });
        assertThat(reports.partyStatementDetail(CLIENT,"AR",from,to,2,1,filters,null,null).rows()).isEmpty();
        var parameters=new LinkedHashMap<String,String>();
        filters.forEach((key,value)->parameters.put("f."+key,value));
        parameters.put("partyId",CLIENT.toString());parameters.put("side","AR");
        parameters.put("dateFrom",from.toString());parameters.put("dateTo",to.toString());
        assertThat(reports.export("statement/detail",parameters,null,null).rows()).hasSize(1);
        assertThat(reports.partyStatementFlow(CLIENT,"AR",from,to,1,50,
                PartyStatementHeaderQuery.withKeyword(Map.of(),"TARGET CASH"),null,null).rows()).hasSize(1);
    }

    @Test
    void accountHeaderFiltersKeepTheFullRunningBalanceAndFilteredTotalsAcrossPagingAndExport() {
        UUID first=UUID.randomUUID(),target=UUID.randomUUID(),last=UUID.randomUUID();
        db.update("""
                INSERT INTO finance_reconciliations(id,account_id,bill_date,posting_seq,bill_no,
                    in_amount,out_amount,entry_kind,source_doc_type,remark,counterpart_name,check_no,source_remark,settled_date,is_deleted)
                VALUES(?,?,'2026-10-12 00:00:00+08',1,'EARLIER',10,0,'POSTING','INCOME','排除的前笔','其他单位','CHECK-A','普通来源',NULL,FALSE),
                      (?,?,'2026-10-12 01:00:00+08',2,'TARGET',0,2.0001,'ADJUSTMENT','BALANCE_ADJUSTMENT','目标退款','目标单位','CHECK-B','余额调整来源','2026-10-12 02:00:00+08',FALSE),
                      (?,?,'2026-10-12 02:00:00+08',3,'LATER',5.0002,0,'POSTING','INCOME','排除的后笔','其他单位','CHECK-C','普通来源',NULL,FALSE)
                """,first,ACCOUNT,target,ACCOUNT,last,ACCOUNT);
        Map<String,String> columns=Map.ofEntries(
                Map.entry("search.summary","目标"),Map.entry("search.counterpartName","目标单位"),
                Map.entry("search.checkNo","CHECK-B"),Map.entry("search.source","调整"),
                Map.entry("search.billDate","2026-10-12"),Map.entry("search.settledDate","2026-10-12"),
                Map.entry("search.balance","=10.9999"),Map.entry("search.outAmount",">=2.0001"),
                Map.entry("entryKind","ADJUSTMENT"),Map.entry("sourceDocType","BALANCE_ADJUSTMENT"));
        var filtered=reports.accountStatement(ACCOUNT,DATE,DATE,null,1,1,null,columns);
        assertThat(filtered.total()).isEqualTo(1);
        assertThat(filtered.rows()).singleElement().satisfies(row->{
            assertThat(row.get("billNo")).isEqualTo("TARGET");
            assertThat((BigDecimal)row.get("balance")).isEqualByComparingTo("10.9999");
            assertThat(row.get("balanceText")).isEqualTo("10.9999");
            assertThat(row.get("__accountCurrencyName")).isEqualTo("美金");
        });
        assertThat(filtered.totals()).anySatisfy(total->{
            assertThat(total.key()).isEqualTo("outAmount");
            assertThat(total.groups().getFirst().value()).isEqualByComparingTo("2.0001");
        });
        assertThat(filtered.totals()).noneMatch(total->total.key().equals("balance"));
        var beyond=reports.accountStatement(ACCOUNT,DATE,DATE,null,2,1,null,columns);
        assertThat(beyond.rows()).isEmpty();assertThat(beyond.total()).isEqualTo(1);
        assertThat(beyond.totals()).anySatisfy(total->{
            assertThat(total.key()).isEqualTo("outAmount");
            assertThat(total.groups().getFirst().value()).isEqualByComparingTo("2.0001");
        });
        var parameters=new LinkedHashMap<>(columns);
        parameters.put("accountId",ACCOUNT.toString());parameters.put("dateFrom",DATE.toString());parameters.put("dateTo",DATE.toString());
        var exported=reports.export("account/statement",parameters,null,null);
        assertThat(exported.rows()).singleElement().satisfies(row->
                assertThat((BigDecimal)row.get("balance")).isEqualByComparingTo("10.9999"));
        assertThat(executedSql).anyMatch(sql->sql.contains("FROM windowed") && sql.contains("column_")
                && sql.indexOf("AS balance")<sql.indexOf("FROM windowed"));
    }
    @BeforeEach void reset(){db.execute("TRUNCATE finance_receipts,finance_receipt_lines,finance_payments,finance_expenses,finance_expense_items,finance_other_incomes,finance_other_income_items,finance_reconciliations,ar_ap_ledger,fixed_assets,deferred_expenses,fa_depreciation_log,da_amortization_log,gl_entries,goods,material_categories,v_stock_actual_cogs_postings,purchase_receipts,purchase_receipt_items,purchase_returns,purchase_return_items,sales_shipments,sales_shipment_items,sales_returns,sales_return_items");executedSql.clear();}
    private static Query query(String sql){
        Query query=mock(Query.class);Map<String,Object> parameters=new LinkedHashMap<>();
        when(query.setMaxResults(anyInt())).thenReturn(query);
        when(query.setParameter(anyString(),any())).thenAnswer(call->{parameters.put(call.getArgument(0),call.getArgument(1));return query;});
        when(query.getResultList()).thenAnswer(call->{executedSql.add(sql);return named.query(sql,parameters,(rs,index)->{
            Object[] row=new Object[rs.getMetaData().getColumnCount()];var aliases=new java.util.ArrayList<String>();
            for(int i=0;i<row.length;i++){row[i]=rs.getObject(i+1);aliases.add(rs.getMetaData().getColumnLabel(i+1));}
            if(sql.contains("LIMIT :__limit OFFSET :__offset")){ dataColumns=List.copyOf(aliases); }return row;
        });});
        when(query.getSingleResult()).thenAnswer(call->{executedSql.add(sql);return named.queryForObject(sql,parameters,Long.class);});return query;
    }
    private static UUID create(String type){
        UUID id=UUID.randomUUID();String table=switch(type){case "RECEIPT"->"finance_receipts";case "PAYMENT"->"finance_payments";case "EXPENSE"->"finance_expenses";default->"finance_other_incomes";};
        db.update("INSERT INTO "+table+"(id,bill_no,bill_date,status,currency_id,account_id,amount_original,amount_local,exchange_rate) VALUES (?,?,?,1,?,?,7,49,7)",id,"REPORT-"+type,DATE,CURRENCY,ACCOUNT);
        if(type.equals("RECEIPT"))db.update("UPDATE finance_receipts SET client_id=? WHERE id=?",CLIENT,id);
        if(type.equals("PAYMENT")){
            db.update("UPDATE finance_payments SET supplier_id=? WHERE id=?",SUPPLIER,id);
            // Ledger settlement and balance are frozen local-currency facts, unlike the payment header's original 7 USD.
            db.update("INSERT INTO ar_ap_ledger(id,source_doc_id,source_doc_type,bill_no,bill_date,currency_id,amount_original,amount_original_local,amount_settled,amount_balance) VALUES (gen_random_uuid(),?,'DIRECT_PAYMENT','LEDGER',?,?,7,49,21,28)",id,DATE,CURRENCY);
        }
        if(type.equals("EXPENSE"))db.update("INSERT INTO finance_expense_items(id,expense_id,bill_date,line_no,qty,price,amount_local) VALUES (gen_random_uuid(),?,?,1,1,7,49)",id,DATE);
        if(type.equals("INCOME"))db.update("INSERT INTO finance_other_income_items(id,income_id,bill_date,line_no,amount_local) VALUES (gen_random_uuid(),?,?,1,49)",id,DATE);
        return id;
    }
    private static ReportTableResponse detail(String type){
        return switch(type){
            case "RECEIPT"->reports.receiptDetail("REPORT-RECEIPT",null,null,null,null,null,null,Map.of(),1,50,null,null);
            case "PAYMENT"->reports.paymentDetail("REPORT-PAYMENT",null,null,null,null,null,null,Map.of(),1,50,null,null);
            case "EXPENSE"->reports.expenseDetail("REPORT-EXPENSE",null,null,null,null,null,null,Map.of(),1,50,null,null);
            default->reports.incomeDetail("REPORT-INCOME",null,null,null,null,null,null,Map.of(),1,50,null,null);
        };
    }
    private static ReportTableResponse summary(String type){
        return switch(type){
            case "RECEIPT"->reports.receiptSummary("REPORT-RECEIPT",null,null,null,null,null,1,50);
            case "PAYMENT"->reports.paymentSummary("REPORT-PAYMENT",null,null,null,null,null,Map.of(),1,50,null,null);
            case "EXPENSE"->reports.expenseSummary("REPORT-EXPENSE",null,null,null,null,null,Map.of(),1,50,null,null);
            default->reports.incomeSummary("REPORT-INCOME",null,null,null,null,null,Map.of(),1,50,null,null);
        };
    }
    private static void valueUnit(ReportTableResponse report,String key,String amount,String unit){
        var row=report.rows().getFirst();assertThat((BigDecimal)row.get(key)).isEqualByComparingTo(amount);
        var column=report.columns().stream().filter(c->c.key().equals(key)).findFirst().orElseThrow();
        String actual=column.unitKey()==null?column.unitLabel():(String)row.get(column.unitKey());assertThat(actual).isEqualTo(unit);
        assertThat(new BigDecimal((String)row.get(key+"Exact"))).isEqualByComparingTo(amount);
    }
    @ParameterizedTest @ValueSource(strings={"RECEIPT","PAYMENT","EXPENSE","INCOME"})
    void realDetailQueriesKeepOriginalAndLocalUnits(String type){
        create(type);var result=detail(type);assertThat(result.rows()).hasSize(1);
        assertThat(dataColumns.stream().filter(key->!key.startsWith("__")).toList()).isEqualTo(result.columns().stream().map(ReportColumn::key).toList());
        valueUnit(result,type.equals("RECEIPT")||type.equals("PAYMENT")?"amountOriginal":"amountTotal","7","美金");
        if(!type.equals("INCOME"))valueUnit(result,"amountLocal","49","元");
        if(type.equals("EXPENSE")){valueUnit(result,"price","7","美金");valueUnit(result,"lineAmount","49","元");}
        assertThat(result.columns()).noneMatch(c->c.key().startsWith("__"));
    }
    @ParameterizedTest @ValueSource(strings={"RECEIPT","PAYMENT","EXPENSE","INCOME"})
    void realSummaryQueriesKeepTheirCurrenciesAndTotals(String type){
        create(type);var result=summary(type);assertThat(result.rows()).hasSize(1);
        assertThat(dataColumns.stream().filter(key->!key.startsWith("__")).toList()).isEqualTo(result.columns().stream().map(ReportColumn::key).toList());
        if(type.equals("RECEIPT")||type.equals("PAYMENT"))valueUnit(result,"amountTotal","7","美金");
        if(type.equals("EXPENSE"))valueUnit(result,"price","7","美金");
        if(type.equals("INCOME"))valueUnit(result,"incomeAmount","49","元");
        valueUnit(result,"amountLocal","49","元");
        if(type.equals("PAYMENT")){valueUnit(result,"paid","21","元");valueUnit(result,"unpaid","28","元");valueUnit(result,"thisBalance","28","元");}
        assertThat(result.totals()).filteredOn(t->t.key().equals("amountLocal")||t.key().equals("lineAmount")||t.key().equals("incomeAmount"))
                .allMatch(t->"元".equals(t.unitLabel()));
    }
    @Test void customerAdvancePaginationKeepsChineseCurrencyAndExactTotals(){
        create("RECEIPT");db.update("UPDATE finance_receipts SET receipt_kind='CUSTOMER_PREPAYMENT'");
        var result=reports.customerPrepaymentEvents(CLIENT,DATE,DATE,1,50);assertThat(result.rows()).hasSize(1);
        valueUnit(result,"prepaymentCashOriginal","7","美金");valueUnit(result,"prepaymentCashLocal","49","元");
        assertThat(result.totals()).anyMatch(t->t.key().equals("prepaymentCashLocal")&&"元".equals(t.unitLabel()));
    }
    @Test void accountStatementUsesAccountCurrencyRatherThanAssumingYuan(){
        db.update("INSERT INTO finance_reconciliations(id,account_id,bill_date,bill_no,posting_seq,in_amount,out_amount) VALUES (gen_random_uuid(),?,?,'REPORT-FLOW',1,7,0)",ACCOUNT,DATE);
        var result=reports.accountStatement(ACCOUNT,DATE,DATE,null,1,50);assertThat(result.rows()).hasSize(1);
        valueUnit(result,"inAmount","7","美金");valueUnit(result,"balance","10","美金");
        assertThat(result.totals()).anyMatch(t->t.key().equals("inAmount")&&"美金".equals(t.unitLabel()));
    }

    @Test void rowOnlyPrepaymentPagesAreBoundedAndKeepTheSameDatedFactsWithoutAggregateQueries(){
        UUID original=create("RECEIPT");
        db.update("UPDATE finance_receipts SET receipt_kind='CUSTOMER_PREPAYMENT'");
        db.update("""
                INSERT INTO finance_receipts(id,bill_no,bill_date,status,currency_id,account_id,client_id,
                    amount_original,amount_local,exchange_rate,receipt_kind)
                SELECT gen_random_uuid(),bill_no||'-SECOND',bill_date,status,currency_id,account_id,client_id,
                    amount_original,amount_local,exchange_rate,receipt_kind FROM finance_receipts WHERE id=?
                """,original);
        var whole=reports.customerPrepaymentEvents(CLIENT,DATE,DATE,1,50);
        assertThat(whole.total()).isEqualTo(2);
        executedSql.clear();
        try(var ignored=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)){
            var first=reports.customerPrepaymentEvents(CLIENT,DATE,DATE,1,1);
            var second=reports.customerPrepaymentEvents(CLIENT,DATE,DATE,2,1);
            var beyond=reports.customerPrepaymentEvents(CLIENT,DATE,DATE,3,1);
            assertThat(first.total()).isEqualTo(-1);assertThat(first.totals()).isEmpty();
            assertThat(first.rows()).containsExactly(whole.rows().get(0));
            assertThat(second.rows()).containsExactly(whole.rows().get(1));
            assertThat(beyond.rows()).isEmpty();
            valueUnit(first,"prepaymentCashOriginal","7","美金");
        }
        assertThat(executedSql).hasSize(3).allSatisfy(sql->assertThat(sql)
                .contains("LIMIT :__limit OFFSET :__offset").doesNotStartWith("SELECT COUNT(*)"));
    }

    @Test void accountRowOnlyPlanKeepsRunningFactsAndEmptyLaterPagesKeepRequestedMetadata(){
        db.update("INSERT INTO finance_reconciliations(id,account_id,bill_date,bill_no,posting_seq,in_amount,out_amount) VALUES (gen_random_uuid(),?,?,'REPORT-FLOW',1,7,0)",ACCOUNT,DATE);
        try(var ignored=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)){
            var first=reports.accountStatement(ACCOUNT,DATE,DATE,null,1,1);
            assertThat(first.total()).isEqualTo(-1);assertThat(first.totals()).isEmpty();
            valueUnit(first,"balance","10","美金");
            assertThat(reports.accountStatement(ACCOUNT,DATE,DATE,null,2,1).rows()).isEmpty();
        }
        assertThat(executedSql).hasSize(2).allSatisfy(sql->assertThat(sql)
                .contains("SUM(flow.in_amount-flow.out_amount) OVER(")
                .doesNotContain("COUNT(*) OVER() AS total_count","SUM(in_amount) OVER() AS total_in","SUM(out_amount) OVER() AS total_out"));
        executedSql.clear();
        var beyond=reports.accountStatement(ACCOUNT,DATE,DATE,null,2,1);
        assertThat(beyond.rows()).isEmpty();assertThat(beyond.total()).isEqualTo(1);
        assertThat(beyond.totalPages()).isEqualTo(1);
        assertThat(beyond.totals()).anySatisfy(total->{
            assertThat(total.key()).isEqualTo("inAmount");assertThat(total.unitLabel()).isEqualTo("美金");
            assertThat(total.groups().getFirst().value()).isEqualByComparingTo("7");
        });
        assertThat(executedSql).hasSize(2);
    }

    @Test void assetSchedulesPageStableMasterIdentitiesBeforeTheirExactActivePostingAggregates(){
        for(int index=1;index<=3;index++){
            UUID asset=UUID.randomUUID(),deferred=UUID.randomUUID();
            db.update("INSERT INTO fixed_assets(id,code,name,original_value,salvage_rate,useful_months,start_period,status) VALUES (?,?,'同名资产',1000.1234,.05,10,'2026-01','在用')",asset,"B1-FA-"+index);
            db.update("INSERT INTO deferred_expenses(id,code,name,total_amount,useful_months,start_period,status) VALUES (?,?,'同名待摊',1000.1234,10,'2026-01','摊销中')",deferred,"B1-DA-"+index);
            for(var source:Map.of("fa_depreciation_log",new Object[]{"asset_id",asset},
                    "da_amortization_log",new Object[]{"deferred_id",deferred}).entrySet()){
                String table=source.getKey(),foreign=source.getValue()[0].toString();Object id=source.getValue()[1];
                db.update("INSERT INTO "+table+"("+foreign+",period,amount,entry_kind,status) VALUES (?,'2026-01',10.0001,'NORMAL','ACTIVE'),(?,'2026-02',20.0002,'NORMAL','ACTIVE'),(?,'2026-03',999,'REVERSAL','ACTIVE'),(?,'2026-04',999,'NORMAL','REVERSED')",id,id,id,id);
            }
        }
        var assets=new FixedAssetService(em,mock(com.uten.imp.security.TxSessionVars.class),access);
        var first=assets.depreciationSchedule(1,1);var second=assets.depreciationSchedule(2,1);
        assertThat(first.total()).isEqualTo(3);assertThat(first.totalPages()).isEqualTo(3);
        assertThat(first.rows().getFirst()).containsEntry("code","B1-FA-1").containsEntry("postedMonths",2L);
        assertThat(second.rows().getFirst()).containsEntry("code","B1-FA-2");
        assertThat((BigDecimal)first.rows().getFirst().get("accumDep")).isEqualByComparingTo("30.0003");
        assertThat((BigDecimal)first.rows().getFirst().get("netValue")).isEqualByComparingTo("970.12");
        assertThat((BigDecimal)first.rows().getFirst().get("monthlyDep")).isEqualByComparingTo("95.01");
        executedSql.clear();
        try(var ignored=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)){
            var page=assets.depreciationSchedule(3,1);var deferred=assets.amortizationSchedule(2,1);
            assertThat(page.total()).isEqualTo(-1);assertThat(page.rows().getFirst()).containsEntry("code","B1-FA-3");
            assertThat(deferred.total()).isEqualTo(-1);assertThat(deferred.rows().getFirst()).containsEntry("code","B1-DA-2");
            assertThat((BigDecimal)deferred.rows().getFirst().get("accumAmt")).isEqualByComparingTo("30.0003");
            assertThat((BigDecimal)deferred.rows().getFirst().get("remain")).isEqualByComparingTo("970.12");
            assertThat(deferred.rows().getFirst().get("accumAmtExact")).isEqualTo("30.0003");
            assertThat(assets.depreciationSchedule(4,1).rows()).isEmpty();
        }
        assertThat(executedSql).hasSize(3).allSatisfy(sql->assertThat(sql)
                .contains("ORDER BY report.\"code\"","LIMIT :__limit OFFSET :__offset","LEFT JOIN LATERAL"));
    }

    @Test void glTrialBalancePaginatesAfterTheCompleteOpeningAndPeriodAggregation() throws Exception {
        for(int index=1;index<=3;index++){
            UUID style=UUID.randomUUID();
            db.update("INSERT INTO payment_styles(id,code,name,category,level) VALUES (?,?,'同名科目','EXPENSE',0)",style,"B1-GL-"+index);
            db.update("INSERT INTO gl_entries(voucher_id,style_id,direction,amount,entry_date,period) VALUES (gen_random_uuid(),?,1,10,?,'2026-09'),(gen_random_uuid(),?,1,7,?,'2026-10'),(gen_random_uuid(),?,-1,2,?,'2026-10')",
                    style,DATE.minusMonths(1),style,DATE,style,DATE);
        }
        var constructor=GlReportService.class.getConstructors()[0];
        var gl=(GlReportService)constructor.newInstance(em,mock(constructor.getParameterTypes()[1]),access);
        var first=gl.trialBalance(DATE.withDayOfMonth(1),DATE,1,1);
        assertThat(first.total()).isEqualTo(3);assertThat(first.rows()).hasSize(1);
        assertThat(first.rows().getFirst()).containsEntry("styleCode","B1-GL-1");
        assertThat((BigDecimal)first.rows().getFirst().get("opening")).isEqualByComparingTo("10");
        assertThat((BigDecimal)first.rows().getFirst().get("closing")).isEqualByComparingTo("15");
        executedSql.clear();
        try(var ignored=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)){
            var second=gl.trialBalance(DATE.withDayOfMonth(1),DATE,2,1);
            assertThat(second.total()).isEqualTo(-1);assertThat(second.rows().getFirst()).containsEntry("styleCode","B1-GL-2");
            assertThat((BigDecimal)second.rows().getFirst().get("opening")).isEqualByComparingTo("10");
            assertThat((BigDecimal)second.rows().getFirst().get("closing")).isEqualByComparingTo("15");
            assertThat(gl.trialBalance(DATE.withDayOfMonth(1),DATE,4,1).rows()).isEmpty();
        }
        assertThat(executedSql).hasSize(2).allSatisfy(sql->assertThat(sql)
                .contains("GROUP BY style_id","ORDER BY report.\"category\",report.\"styleCode\",report.\"styleName\",report.\"__styleId\" LIMIT :__limit OFFSET :__offset"));
    }

    /** Real COGS classification SQL and snapshot; unrelated fixed-row authorities have explicit fixture values. */
    @Test void operatingPlReadsEveryClassificationInBoundedBatchesAndKeepsItsPreciseTotalAndTail() throws Exception {
        db.execute("INSERT INTO material_categories(id,code,name,is_deleted) SELECT gen_random_uuid(),'B1-COGS-'||n,'分类-'||lpad(n::text,5,'0'),false FROM generate_series(1,5001) n");
        db.execute("INSERT INTO goods(id,code,name,category_id,is_deleted) SELECT gen_random_uuid(),code,'分类夹具货品',id,false FROM material_categories WHERE code LIKE 'B1-COGS-%'");
        db.update("INSERT INTO v_stock_actual_cogs_postings(goods_id,business_date,amount_local,pending) SELECT id,?,.1234,right(code,1) IN ('1','3','5','7','9') FROM goods WHERE code LIKE 'B1-COGS-%'",DATE);
        try(var connection=java.sql.DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword())){
            connection.setTransactionIsolation(java.sql.Connection.TRANSACTION_REPEATABLE_READ);
            connection.setReadOnly(true);connection.setAutoCommit(false);
            var cogs=new NamedParameterJdbcTemplate(new org.springframework.jdbc.datasource.SingleConnectionDataSource(connection,true));
            assertThat(cogs.queryForObject("SHOW transaction_isolation",Map.of(),String.class)).isEqualTo("repeatable read");
            assertThat(cogs.queryForObject("SHOW transaction_read_only",Map.of(),String.class)).isEqualTo("on");
            List<Long> offsets=new java.util.ArrayList<>();
            EntityManager authority=mock(EntityManager.class);
            when(authority.createNativeQuery(anyString())).thenAnswer(call->{
                String sql=call.getArgument(0);Query value=mock(Query.class);Map<String,Object> parameters=new LinkedHashMap<>();
                when(value.setParameter(anyString(),any())).thenAnswer(bind->{parameters.put(bind.getArgument(0),bind.getArgument(1));return value;});
                when(value.getSingleResult()).thenReturn(sql.contains("subcontract_receipt_items")?BigDecimal.ZERO:new BigDecimal("1000"));
                when(value.getResultList()).thenAnswer(read->{
                    if(!sql.contains("v_stock_actual_cogs_postings"))return List.of();
                    offsets.add(((Number)parameters.get("__groupOffset")).longValue());
                    assertThat(parameters.get("__groupLimit")).isEqualTo(500);
                    return cogs.query(sql,parameters,(rs,index)->new Object[]{rs.getString(1),rs.getBigDecimal(2),rs.getBoolean(3)});
                });
                return value;
            });
            Class<?> linesType=Class.forName("com.uten.imp.features.finance.gl.GlReportLineSource");
            var linesConstructor=linesType.getDeclaredConstructor(EntityManager.class);linesConstructor.setAccessible(true);
            var constructor=GlReportService.class.getConstructors()[0];
            var gl=(GlReportService)constructor.newInstance(authority,linesConstructor.newInstance(authority),access);
            var user=new com.uten.imp.security.AuthUser(UUID.randomUUID(),UUID.randomUUID(),"cogs-projection",
                    Set.of("finance_report:view","finance_report:export","finance:view:all"),false,true,false);
            org.springframework.security.core.context.SecurityContextHolder.getContext().setAuthentication(
                    new org.springframework.security.authentication.UsernamePasswordAuthenticationToken(user,null,user.getAuthorities()));
            org.springframework.transaction.support.TransactionSynchronizationManager.setActualTransactionActive(true);
            org.springframework.transaction.support.TransactionSynchronizationManager.setCurrentTransactionReadOnly(true);
            org.springframework.transaction.support.TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(java.sql.Connection.TRANSACTION_REPEATABLE_READ);
            try{
                List<com.uten.imp.common.export.ExportPayload> batches=new java.util.ArrayList<>();
                try(var sink=com.uten.imp.common.export.ExportPageSink.open(batches::add)){
                    var result=gl.exportInCurrentSnapshot("gl/operating-pl",DATE,DATE.getYear(),DATE.getMonthValue(),10_000);
                    assertThat(result.rows()).isEmpty();
                    assertThat(result.total()).isEqualTo(batches.stream().mapToLong(batch->batch.rows().size()).sum());
                }
                assertThat(offsets).containsExactlyElementsOf(java.util.stream.LongStream.rangeClosed(0,10).map(value->value*500).boxed().toList());
                assertThat(batches).allSatisfy(batch->assertThat(batch.rows().size()).isLessThanOrEqualTo(500));
                var output=batches.stream().flatMap(batch->batch.rows().stream()).toList();
                assertThat(output.stream().filter(row->"库存价值".equals(row.get("sub"))).map(row->row.get("item")))
                        .containsExactlyElementsOf(java.util.stream.IntStream.rangeClosed(1,5001)
                                .mapToObj(value->"分类-"+String.format("%05d",value)).toList());
                assertThat(output).anySatisfy(row->{
                    assertThat(row.get("sub")).isEqualTo("销售成本合计");
                    assertThat((BigDecimal)row.get("amount")).isEqualByComparingTo(new BigDecimal(".1234").multiply(new BigDecimal("5001")));
                });
                assertThat(output.getLast().get("sub")).isEqualTo("管理费合计");
                var page=gl.operatingPlPage(DATE.getYear(),DATE.getMonthValue(),2,500);
                assertThat(page.rows()).containsExactlyElementsOf(output.subList(500,1000));
                assertThat(page.total()).isEqualTo(output.size());
            } finally {
                org.springframework.transaction.support.TransactionSynchronizationManager.clear();
                org.springframework.security.core.context.SecurityContextHolder.clearContext();
                connection.rollback();
            }
        }
    }

    @Test void accountSearchMatchesAllWordsLiterallyAfterRunningBalancesAndBeforePagingTotalsAndFacets(){
        db.update("INSERT INTO finance_reconciliations(id,account_id,bill_date,bill_no,posting_seq,in_amount,out_amount) VALUES (gen_random_uuid(),?,?,'OPENING',1,100,0)",ACCOUNT,DATE.minusDays(1));
        db.update("INSERT INTO finance_reconciliations(id,account_id,bill_date,bill_no,posting_seq,counterpart_name,remark,in_amount,out_amount) VALUES (gen_random_uuid(),?,?,'A%_B',2,'张三','办公',10,0),(gen_random_uuid(),?,?,'HIDDEN',3,'其他','不应显示',20,0),(gen_random_uuid(),?,?,'A%_B-2',4,'张三','办公',0,5),(gen_random_uuid(),?,?,'AxYB',5,'张三','办公',9,0)",
                ACCOUNT,DATE,ACCOUNT,DATE,ACCOUNT,DATE,ACCOUNT,DATE);
        var first=reports.accountStatement(ACCOUNT,DATE,DATE,"张三\u3000A%_B",1,1);
        var second=reports.accountStatement(ACCOUNT,DATE,DATE,"张三 A%_B",2,1);
        assertThat(first.total()).isEqualTo(2);assertThat(first.totalPages()).isEqualTo(2);
        assertThat(first.rows().getFirst()).containsEntry("billNo","A%_B");
        assertThat(second.rows().getFirst()).containsEntry("billNo","A%_B-2");
        assertThat((BigDecimal)first.rows().getFirst().get("balance")).isEqualByComparingTo("113");
        assertThat((BigDecimal)second.rows().getFirst().get("balance")).isEqualByComparingTo("128");
        assertThat(first.totals().stream().filter(total->total.key().equals("inAmount")).findFirst().orElseThrow().groups().getFirst().value()).isEqualByComparingTo("10");
        assertThat(first.totals().stream().filter(total->total.key().equals("outAmount")).findFirst().orElseThrow().groups().getFirst().value()).isEqualByComparingTo("5");
        assertThat(reports.accountStatementFacets(ACCOUNT,DATE,DATE,"张三 A%_B").get("billNo"))
                .extracting(row->row.get("value")).containsExactly("A%_B","A%_B-2");
        assertThat(reports.accountStatement(ACCOUNT,DATE,DATE,"张三 missing",1,20).total()).isZero();
    }

    @Test void sameChineseCurrencyLabelsKeepTheirActualLedgerIdentitiesSeparate(){
        UUID second=UUID.randomUUID();
        db.update("INSERT INTO currencies(id,name,code) VALUES (?,'US Dollar','USD')",second);
        for(var value:Map.of(CURRENCY,new BigDecimal("11.0001"),second,new BigDecimal("31.0002")).entrySet()){
            db.update("""
                    INSERT INTO ar_ap_ledger(id,direction,client_id,currency_id,status,is_deleted,bill_no,bill_date,
                        amount_original,amount_original_local,amount_received_original,amount_received_local,
                        amount_write_off_original,amount_write_off_local,amount_offset_original,amount_offset_local,
                        amount_balance_original,amount_balance)
                    VALUES (?, 'AR', ?, ?, 1, false, ?, ?, ?, ?, 0, 0, 0, 0, 0, 0, ?, ?)
                    """,UUID.randomUUID(),CLIENT,value.getKey(),"IDENTITY-"+value.getKey(),DATE,
                    value.getValue(),value.getValue().multiply(new BigDecimal("7")),value.getValue(),
                    value.getValue().multiply(new BigDecimal("7")));
        }
        var result=reports.arApDetail("AR",null,CLIENT,null,DATE,DATE,null,Map.of(),1,50,null,null);
        var total=result.totals().stream().filter(t->t.key().equals("amountOriginal")).findFirst().orElseThrow();
        assertThat(total.groups()).hasSize(2);
        assertThat(total.groups()).extracting(com.uten.imp.common.report.ReportTotalGroup::unit).containsOnly("美金");
        assertThat(total.groups()).extracting(com.uten.imp.common.report.ReportTotalGroup::identity)
                .containsExactlyInAnyOrder(CURRENCY.toString(),second.toString());
        assertThat(total.groups()).extracting(com.uten.imp.common.report.ReportTotalGroup::value)
                .containsExactlyInAnyOrder(new BigDecimal("11.0001"),new BigDecimal("31.0002"));
    }

    @Test void arApCategoryUnionUsesTypedBranchesBeforePagingAndKeepsTotalsAndPublicColumnsStable(){
        String word="联合类别"+UUID.randomUUID().toString().substring(0,8);
        UUID clientRoot=UUID.randomUUID(),clientLeaf=UUID.fromString("ffffffff-ffff-ffff-ffff-fffffffffff0"),
                otherClientCategory=UUID.fromString("00000000-0000-0000-0000-000000000001");
        UUID supplierMatch=UUID.randomUUID();
        db.update("INSERT INTO client_categories(id,code,name,parent_id,is_deleted) VALUES (?,? ,?,NULL,false),(?,?,'下级客户',?,false),(?,?,'其他客户类别',NULL,false)",
                clientRoot,"CC-"+clientRoot,word,clientLeaf,"CC-"+clientLeaf,clientRoot,otherClientCategory,"CC-"+otherClientCategory);
        // Same UUID in independent category domains must not turn the client match into supplier access.
        db.update("INSERT INTO supplier_categories(id,code,name,is_deleted) VALUES (?,?,'不相关供应商类别',false),(?,?,?,false)",
                clientRoot,"SC-"+clientRoot,supplierMatch,"SC-"+supplierMatch,word);
        UUID direct=UUID.randomUUID(),near=UUID.randomUUID(),supplier=UUID.randomUUID(),wrongType=UUID.randomUUID();
        db.update("INSERT INTO clients(id,code,name,category_id,is_deleted) VALUES (?,?,'甲公司',?,false),(?,?,?,?,false)",
                direct,"C-"+direct,clientLeaf,near,"C-"+near,"备件"+word+"专营",otherClientCategory);
        db.update("INSERT INTO suppliers(id,code,name,category_id,is_deleted) VALUES (?,?,'乙供应商',?,false),(?,?,'不应混入',?,false)",
                supplier,"S-"+supplier,supplierMatch,wrongType,"S-"+wrongType,clientRoot);
        categoryLedger("AR",direct,new BigDecimal("21.1250"));
        categoryLedger("AR",near,new BigDecimal("37.8750"));
        categoryLedger("AP",supplier,new BigDecimal("11.2500"));
        categoryLedger("AP",wrongType,new BigDecimal("9999"));

        var locations=reports.arApPartyLocations(word,1,100);
        assertThat(locations.getTotal()).isEqualTo(3);
        assertThat(locations.getItems().getFirst()).isEqualTo(new ArApPartyLocation("CLIENT",otherClientCategory));
        assertThat(locations.getItems()).containsExactlyInAnyOrder(
                new ArApPartyLocation("CLIENT",clientLeaf),new ArApPartyLocation("CLIENT",otherClientCategory),
                new ArApPartyLocation("SUPPLIER",supplierMatch));
        var pagedLocations=new java.util.ArrayList<ArApPartyLocation>();
        for(int page=1;page<=3;page++)pagedLocations.addAll(reports.arApPartyLocations(word,page,1).getItems());
        assertThat(pagedLocations).containsExactlyInAnyOrderElementsOf(locations.getItems());

        var first=reports.arApOverview(DATE,DATE,"ANY",word,null,null,1,1);
        var second=reports.arApOverview(DATE,DATE,"ANY",word,null,null,2,1);
        var third=reports.arApOverview(DATE,DATE,"ANY",word,null,null,3,1);
        assertThat(first.total()).isEqualTo(3);
        assertThat(first.totalPages()).isEqualTo(3);
        assertThat(first.rows().getFirst()).containsEntry("partyName","备件"+word+"专营");
        assertThat(List.of(second.rows().getFirst().get("partyName"),third.rows().getFirst().get("partyName")))
                .containsExactlyInAnyOrder("甲公司","乙供应商");
        assertThat(first.totals().stream().filter(total->total.key().equals("receivable")).findFirst().orElseThrow().groups().getFirst().value())
                .isEqualByComparingTo("59.0000");
        assertThat(first.totals().stream().filter(total->total.key().equals("payable")).findFirst().orElseThrow().groups().getFirst().value())
                .isEqualByComparingTo("11.2500");
        assertThat(first.columns()).extracting(ReportColumn::key)
                .containsExactly("partyName","partyType","receivable","payable","phone","address");
        assertThat(first.rows().getFirst()).doesNotContainKeys("partyCode","partyCategoryId","searchRank");
        var scoped=reports.arApOverview(DATE,DATE,"ANY",word,"CLIENT",clientRoot,1,50);
        assertThat(scoped.total()).isEqualTo(1);
        assertThat(scoped.rows().getFirst()).containsEntry("partyName","甲公司");
        assertThat(reports.arApOverview(DATE,DATE,"ANY",word,"SUPPLIER",clientRoot,1,50).total()).isZero();
    }

    private static void categoryLedger(String direction,UUID party,BigDecimal balance){
        String field=direction.equals("AR")?"client_id":"supplier_id";
        db.update("INSERT INTO ar_ap_ledger(id,direction,"+field+",currency_id,status,is_deleted,bill_no,bill_date,amount_balance) VALUES (?,?,?,?,1,false,?,?,?)",
                UUID.randomUUID(),direction,party,CURRENCY,"CATEGORY-"+UUID.randomUUID(),DATE,balance);
    }

    @Test void overviewSameNamePartiesRetainStableIdentityOrderAcrossThreePages() {
        String key="同名往来"+UUID.randomUUID().toString().substring(0,8);
        db.update("""
            INSERT INTO clients(id,code,name,phone,is_deleted)
            SELECT md5(?||n)::uuid,'SAME-'||?||n,?,'PHONE-'||lpad(n::text,4,'0'),false FROM generate_series(1,1001)n
            """,key,key,key);
        List<String> expected=db.queryForList("SELECT phone FROM clients WHERE name=? ORDER BY id",String.class,key);
        var actual=new java.util.ArrayList<String>();executedSql.clear();
        try(var ignored=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)) {
            for(int page=1;page<=3;page++) {
                var result=reports.arApOverview(null,null,"ALL",key,"CLIENT",null,page,400);
                assertThat(result.total()).isEqualTo(-1);assertThat(result.totals()).isEmpty();
                actual.addAll(result.rows().stream().map(row->(String)row.get("phone")).toList());
            }
        }
        assertThat(actual).containsExactlyElementsOf(expected);assertThat(actual.stream().distinct()).hasSize(1001);
        assertThat(executedSql).hasSize(3);
    }

    @ParameterizedTest @ValueSource(strings={"supplier","client"})
    void statementsWithEqualDatesNamesAndCrossSourceUuidRemainCompleteAndStable(String kind) {
        boolean supplier=kind.equals("supplier");UUID goods=UUID.randomUUID(),unit=UUID.randomUUID(),document=UUID.randomUUID(),returned=UUID.randomUUID();
        db.update("INSERT INTO units(id,code,name) VALUES(?,?,'个')",unit,"SAME-U-"+unit);
        db.update("INSERT INTO goods(id,code,name,unit_id) VALUES(?,'SAME-GOODS','同名产品',?)",goods,unit);
        String head=supplier?"purchase_receipts":"sales_shipments",items=supplier?"purchase_receipt_items":"sales_shipment_items";
        String returns=supplier?"purchase_returns":"sales_returns",returnItems=supplier?"purchase_return_items":"sales_return_items";
        String party=supplier?"supplier_id":"client_id",link=supplier?"receipt_id":"shipment_id";
        db.update("INSERT INTO "+head+"(id,bill_no,bill_date,status,is_deleted,"+party+") VALUES(?,'SAME-DOC',?,1,false,?)",document,DATE,supplier?SUPPLIER:CLIENT);
        db.update("INSERT INTO "+returns+"(id,bill_no,bill_date,status,is_deleted,"+party+") VALUES(?,'SAME-DOC-RETURN',?,1,false,?)",returned,DATE,supplier?SUPPLIER:CLIENT);
        db.update("INSERT INTO "+items+"(id,"+link+",bill_no,bill_date,goods_id,unit_id,line_no,qty,price,amount_original,is_deleted) "
                +"SELECT ('90000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,?,'SAME-DOC',?,?,?,n,n,.0001,n*.0001,false FROM generate_series(1,1001)n",
                document,DATE,goods,unit);
        // Different business sources can legitimately have the same UUID. Their discriminator remains part of the order.
        db.update("INSERT INTO "+returnItems+"(id,return_id,bill_no,bill_date,goods_id,unit_id,qty,price,amount_original,is_deleted) "
                +"VALUES('90000000-0000-0000-0000-000000000001',?,'SAME-DOC-RETURN',?,?,?,1009,.0001,.1009,false)",returned,DATE,goods,unit);
        var service=new FinanceStatementService(em,access);var actual=new java.util.ArrayList<BigDecimal>();
        try(var ignored=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)) {
            for(int page=1;page<=3;page++) {
                var result=supplier?service.supplierStatement(null,DATE,DATE,page,400):service.clientStatement(null,DATE,DATE,page,400);
                assertThat(result.total()).isEqualTo(-1);
                actual.addAll(result.rows().stream().map(row->(BigDecimal)row.get("qty")).toList());
            }
        }
        var expected=new java.util.ArrayList<BigDecimal>();
        if(!supplier)expected.add(new BigDecimal("-1009"));
        java.util.stream.IntStream.rangeClosed(1,1001).forEach(index->expected.add(BigDecimal.valueOf(index)));
        if(supplier)expected.add(new BigDecimal("-1009"));
        assertThat(actual).usingElementComparator(BigDecimal::compareTo).containsExactlyElementsOf(expected);
    }
}
