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
    private static final UUID CLIENT=UUID.randomUUID(),SUPPLIER=UUID.randomUUID(),CURRENCY=UUID.randomUUID(),ACCOUNT=UUID.randomUUID(),ASSET_EXPENSE=UUID.randomUUID();
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
                "fixed_assets","deferred_expenses","fa_depreciation_log","da_amortization_log","gl_vouchers","gl_entries",
                "goods","material_categories","v_stock_actual_cogs_postings","units","colors","stock_movements",
                "purchase_receipts","purchase_receipt_items","purchase_returns","purchase_return_items","sales_returns","sales_return_items",
                "party_monthly_summaries","party_month_dirty","finance_payment_lines","supplier_open_item_offsets","legacy_finance_import_sources",
                "finance_asset_books","finance_asset_categories","finance_deferral_schedule_versions","finance_deferral_schedule_lines",
                "finance_asset_posting_runs","finance_asset_posting_lines","finance_asset_template_metadata","finance_asset_opening_groups",
                "finance_asset_opening_members","finance_asset_opening_entry_claims","finance_asset_template_history","finance_template_sources",
                "finance_gl_opening_baselines","finance_accounting_import_batches","finance_gl_period_versions","finance_accounting_period_coverage",
                "finance_gl_voucher_evidence","finance_chart_codes","finance_chart_code_styles",
                "v_stock_actual_sales_cost_coverage","finance_sales_cost_inputs","v_finance_sales_expense_client_facts","v_finance_sales_expense_period_coverage");
        // Cash-event book rates call the real migrated precision functions; without them the
        // class-42 "function does not exist" surfaces as Spring bad SQL grammar.
        MigratedProjectionSchema.createCurrentFunctions(db,"fn_business_decimal_from_integer",
                "fn_business_exact_divide_with_policy","fn_business_exact_divide");
        db.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto");
        MigratedProjectionSchema.createCurrentFunctions(db,"fn_finance_gl_voucher_is_booked","fn_finance_balance_asof_complete",
                "fn_finance_style_balance_asof","fn_finance_style_balance_evidence_fingerprint","fn_finance_asset_opening_group_valid");
        MigratedProjectionSchema.createCurrentViews(db,"v_finance_asset_posting_facts","v_finance_asset_report_facts");
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
        db.update("INSERT INTO payment_styles(id,code,name,category,level) VALUES(?,'REPORT-ASSET-EXPENSE','计提费用','EXPENSE',0)",ASSET_EXPENSE);
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
    @BeforeEach void reset(){
        db.execute("TRUNCATE finance_receipts,finance_receipt_lines,finance_payments,finance_expenses,finance_expense_items,finance_other_incomes,finance_other_income_items,finance_reconciliations,ar_ap_ledger,fixed_assets,deferred_expenses,fa_depreciation_log,da_amortization_log,gl_entries,gl_vouchers,goods,material_categories,v_stock_actual_cogs_postings,purchase_receipts,purchase_receipt_items,purchase_returns,purchase_return_items,sales_shipments,sales_shipment_items,sales_returns,sales_return_items");
        db.execute("TRUNCATE finance_asset_books,finance_deferral_schedule_versions,finance_asset_posting_runs,finance_asset_posting_lines,finance_asset_template_metadata,finance_asset_opening_groups,finance_asset_opening_members,finance_asset_opening_entry_claims,finance_asset_template_history,finance_gl_opening_baselines,finance_accounting_import_batches,finance_gl_period_versions,finance_accounting_period_coverage,finance_gl_voucher_evidence,finance_chart_codes,finance_chart_code_styles,v_stock_actual_sales_cost_coverage,finance_sales_cost_inputs,v_finance_sales_expense_client_facts,v_finance_sales_expense_period_coverage");
        db.update("DELETE FROM clients WHERE id<>?",CLIENT);
        executedSql.clear();
    }
    private static Query query(String sql){
        Query query=mock(Query.class);Map<String,Object> parameters=new LinkedHashMap<>();
        when(query.setMaxResults(anyInt())).thenReturn(query);
        when(query.setParameter(anyString(),any())).thenAnswer(call->{parameters.put(call.getArgument(0),call.getArgument(1));return query;});
        when(query.getResultList()).thenAnswer(call->{executedSql.add(sql);return named.query(sql,parameters,(rs,index)->{
            Object[] row=new Object[rs.getMetaData().getColumnCount()];var aliases=new java.util.ArrayList<String>();
            for(int i=0;i<row.length;i++){row[i]=rs.getObject(i+1);aliases.add(rs.getMetaData().getColumnLabel(i+1));}
            if(sql.contains("LIMIT :__limit OFFSET :__offset")){ dataColumns=List.copyOf(aliases); }return row;
        });});
        when(query.getSingleResult()).thenAnswer(call->{executedSql.add(sql);return named.queryForObject(sql,parameters,Object.class);});return query;
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
    @Test void advanceArrivalIsCashWithoutPretendingToReduceAnyReceivableInReceiptReportsAndExports() {
        create("RECEIPT");db.update("UPDATE finance_receipts SET receipt_kind='CUSTOMER_PREPAYMENT'");
        var detail=reports.receiptDetail(null,CLIENT,null,null,DATE,DATE,null,Map.of(),1,50,null,null);
        var summary=reports.receiptSummary(null,CLIENT,null,DATE,DATE,null,1,50);
        for(var result:List.of(detail,summary)) {
            valueUnit(result,"amountLocal","49","元");valueUnit(result,"appliedLocal","0","元");
            assertThat(result.totals()).anySatisfy(total->{
                assertThat(total.key()).isEqualTo("appliedLocal");
                assertThat(total.groups().getFirst().value()).isZero();
            });
        }
        for(String report:List.of("receipt/detail","receipt/summary")) {
            var payload=reports.export(report,Map.of("clientId",CLIENT.toString(),"dateFrom",DATE.toString(),"dateTo",DATE.toString()),null,null);
            assertThat(payload.rows()).singleElement().satisfies(row->{
                assertThat((BigDecimal)row.get("amountLocal")).isEqualByComparingTo("49");
                assertThat((BigDecimal)row.get("appliedLocal")).isZero();
            });
        }
    }
    @Test void incomeClassificationAmountsRemainThirtyAndSeventyWhileTheDocumentIsOneHundred() throws Exception {
        UUID id=create("INCOME");
        db.update("UPDATE finance_other_incomes SET amount_original=100,amount_local=100 WHERE id=?",id);
        db.update("UPDATE finance_other_income_items SET amount_local=30,summary='分类甲' WHERE income_id=?",id);
        db.update("INSERT INTO finance_other_income_items(id,income_id,bill_date,line_no,amount_local,summary) VALUES (gen_random_uuid(),?,?,2,70,'分类乙')",id,DATE);
        var detail=reports.incomeDetail(null,null,null,null,DATE,DATE,null,Map.of(),1,50,null,null);
        assertThat(detail.rows()).extracting(row->(BigDecimal)row.get("amountTotal")).allSatisfy(amount->assertThat(amount).isEqualByComparingTo("100"));
        assertThat(detail.rows()).extracting(row->(BigDecimal)row.get("incomeAmount")).usingElementComparator(BigDecimal::compareTo).containsExactly(new BigDecimal("30"),new BigDecimal("70"));
        assertThat(detail.totals()).singleElement().satisfies(total->{assertThat(total.key()).isEqualTo("incomeAmount");assertThat(total.groups().getFirst().value()).isEqualByComparingTo("100");});
        var exported=reports.export("income/detail",Map.of("dateFrom",DATE.toString(),"dateTo",DATE.toString()),null,null);
        assertThat(exported.rows()).containsExactlyElementsOf(detail.rows());
        byte[] bytes=new com.uten.imp.common.export.XlsxExportService().build(exported.columns(),exported.rows());
        try(var workbook=new org.apache.poi.xssf.usermodel.XSSFWorkbook(new java.io.ByteArrayInputStream(bytes))) {
            int column=java.util.stream.IntStream.range(0,exported.columns().size()).filter(i->exported.columns().get(i).key().equals("incomeAmount")).findFirst().orElseThrow();
            assertThat(workbook.getSheetAt(0).getLastRowNum()).isEqualTo(2);
            assertThat(workbook.getSheetAt(0).getRow(1).getCell(column).getNumericCellValue()).isEqualTo(30);
            assertThat(workbook.getSheetAt(0).getRow(2).getCell(column).getNumericCellValue()).isEqualTo(70);
        }
        var filtered=reports.incomeDetail(null,null,null,null,DATE,DATE,null,Map.of("search.incomeAmount",">=70"),1,50,null,null);
        assertThat(filtered.rows()).singleElement().satisfies(row->assertThat((BigDecimal)row.get("incomeAmount")).isEqualByComparingTo("70"));
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
        LocalDate cutoff=LocalDate.of(2026,2,28);
        var fixedIds=new java.util.ArrayList<String>();var deferredIds=new java.util.ArrayList<String>();
        for(int index=1;index<=3;index++){
            UUID asset=assetScheduleMaster(false,"B1-FA-"+index,LocalDate.of(2025,12,31),null,null,false,new BigDecimal("40.0004"));
            UUID deferred=assetScheduleMaster(true,"B1-DA-"+index,LocalDate.of(2025,12,31),null,null,false,BigDecimal.ZERO);
            fixedIds.add(asset.toString());deferredIds.add(deferred.toString());
            for(boolean isDeferred:List.of(false,true)){
                UUID id=isDeferred?deferred:asset;
                assetSchedulePosting(isDeferred,id,"2026-01","10.0001","NORMAL","ACTIVE",LocalDate.of(2026,1,31),false);
                assetSchedulePosting(isDeferred,id,"2026-02","20.0002","NORMAL","ACTIVE",cutoff,false);
                assetSchedulePosting(isDeferred,id,"2026-01","37.0007","NORMAL","REVERSED",LocalDate.of(2026,1,31),false);
                assetSchedulePosting(isDeferred,id,"2026-02","37.0007","REVERSAL","ACTIVE",LocalDate.of(2026,2,14),false);
                assetSchedulePosting(isDeferred,id,"2026-02","99.0009","NORMAL","ACTIVE",cutoff,true);
                assetSchedulePosting(isDeferred,id,"2026-03","44.0004","NORMAL","ACTIVE",LocalDate.of(2026,3,31),false);
            }
        }
        fixedIds.sort(String::compareTo);deferredIds.sort(String::compareTo);
        var assets=new FixedAssetService(em,mock(com.uten.imp.security.TxSessionVars.class),access);
        var first=assetScheduleReport(assets,false,1,1,cutoff);var second=assetScheduleReport(assets,false,2,1,cutoff);
        assertThat(first.total()).isEqualTo(3);assertThat(first.totalPages()).isEqualTo(3);
        assertThat(first.rows().getFirst()).containsEntry("__assetId",fixedIds.getFirst()).containsEntry("assetName","同名资产");
        assertThat(second.rows().getFirst()).containsEntry("__assetId",fixedIds.get(1));
        // The recorded opening balance is preserved without inventing its
        // historical month allocation. Native postings still determine net value.
        assertThat(first.rows().getFirst().get("accumDep")).isNull();
        assertThat(first.rows().getFirst().get("__pending")).isEqualTo(true);
        assertThat((BigDecimal)first.rows().getFirst().get("netValue")).isEqualByComparingTo("930.1227");
        assertThat((BigDecimal)first.rows().getFirst().get("monthlyDep")).isEqualByComparingTo("20.0002");
        executedSql.clear();
        try(var ignored=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)){
            var page=assetScheduleReport(assets,false,3,1,cutoff);var deferred=assetScheduleReport(assets,true,2,1,cutoff);
            assertThat(page.total()).isEqualTo(-1);assertThat(page.rows().getFirst()).containsEntry("__assetId",fixedIds.get(2));
            assertThat(deferred.total()).isEqualTo(-1);assertThat(deferred.rows().getFirst()).containsEntry("__assetId",deferredIds.get(1));
            assertThat((BigDecimal)deferred.rows().getFirst().get("accumAmt")).isEqualByComparingTo("30.0003");
            assertThat((BigDecimal)deferred.rows().getFirst().get("remain")).isEqualByComparingTo("970.1231");
            assertThat((BigDecimal)deferred.rows().getFirst().get("monthlyAmt")).isEqualByComparingTo("20.0002");
            assertThat(deferred.rows().getFirst().get("accumAmtExact")).isEqualTo("30.0003");
            assertThat(assetScheduleReport(assets,false,4,1,cutoff).rows()).isEmpty();
        }
        assertThat(executedSql).hasSize(3).allSatisfy(sql->assertThat(sql)
                .contains("ORDER BY report.\"assetName\",report.\"__assetId\"","LIMIT :__limit OFFSET :__offset","LEFT JOIN LATERAL","v_finance_asset_report_facts"));
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void assetCutoffsUseVoucherDatesLegacyMonthEndsAndRecognitionLifecycle(boolean deferred){
        LocalDate cutoff=LocalDate.of(2026,2,15),recognized=LocalDate.of(2025,12,31);
        BigDecimal opening=deferred?BigDecimal.ZERO:new BigDecimal("4.0004");
        UUID id=assetScheduleMaster(deferred,"ASOF-01",recognized,null,null,false,opening);
        // Current closed state must not erase a row that was still active at the requested date.
        UUID laterClosed=assetScheduleMaster(deferred,"ASOF-02",recognized,LocalDate.of(2026,3,1),null,false,BigDecimal.ZERO);
        assetScheduleMaster(deferred,"IGNORED-DRAFT",null,null,null,false,BigDecimal.ZERO);
        assetScheduleMaster(deferred,"IGNORED-FUTURE",LocalDate.of(2026,3,1),null,null,false,BigDecimal.ZERO);
        assetScheduleMaster(deferred,"IGNORED-CLOSED",recognized,cutoff,null,false,BigDecimal.ZERO);
        assetScheduleMaster(deferred,"IGNORED-REVERSED",recognized,null,cutoff,false,BigDecimal.ZERO);
        assetScheduleMaster(deferred,"IGNORED-DELETED",recognized,null,null,true,BigDecimal.ZERO);
        assetSchedulePosting(deferred,id,"2026-02","7.0001","NORMAL","ACTIVE",cutoff.minusDays(1),false);
        assetSchedulePosting(deferred,id,"2026-02","2.0002","NORMAL","ACTIVE",null,false);
        assetSchedulePosting(deferred,id,"2026-03","31.0003","NORMAL","ACTIVE",LocalDate.of(2026,3,1),false);
        var assets=new FixedAssetService(em,mock(com.uten.imp.security.TxSessionVars.class),access);
        String accumulated=deferred?"accumAmt":"accumDep",monthly=deferred?"monthlyAmt":"monthlyDep";
        var midMonth=assetScheduleReport(assets,deferred,1,50,cutoff);
        var identities=java.util.stream.Stream.of(id,laterClosed).map(UUID::toString).sorted().toList();
        assertThat(midMonth.rows()).extracting(row->row.get("__assetId")).containsExactlyElementsOf(identities);
        var current=midMonth.rows().stream().filter(row->id.toString().equals(row.get("__assetId"))).findFirst().orElseThrow();
        assertThat((BigDecimal)current.get(monthly)).isEqualByComparingTo("20.0002"); // frozen nominal installment, not actual monthly activity
        if(deferred)assertThat((BigDecimal)current.get(accumulated)).isEqualByComparingTo("7.0001");
        else assertThat(current.get(accumulated)).isNull(); // original opening has no proved historical-month distribution
        assertThat((BigDecimal)current.get(deferred?"remain":"netValue"))
                .isEqualByComparingTo(new BigDecimal("1000.1234").subtract(opening).subtract(new BigDecimal("7.0001")));
        assertThat(db.queryForObject("SELECT count(*) FROM v_finance_asset_posting_facts WHERE object_id=? AND business_date<=?",Long.class,id,cutoff)).isEqualTo(1);
        var monthEnd=assetScheduleReport(assets,deferred,1,50,LocalDate.of(2026,2,28));
        assertThat(monthEnd.rows()).extracting(row->row.get("__assetId")).containsExactlyElementsOf(identities);
        var atEnd=monthEnd.rows().stream().filter(row->id.toString().equals(row.get("__assetId"))).findFirst().orElseThrow();
        assertThat(atEnd.get(accumulated)).isNull();
        assertThat(atEnd.get(deferred?"remain":"netValue")).isNull();
        assertThat(atEnd.get("__pending")).isEqualTo(true);
        assertThat(db.queryForObject("SELECT count(*) FROM v_finance_asset_posting_facts WHERE object_id=? AND business_date<=?",Long.class,id,LocalDate.of(2026,2,28))).isEqualTo(2);
        assertThat(db.queryForObject("SELECT amount_local FROM v_finance_asset_posting_facts WHERE object_id=? AND business_date='2026-02-28' AND pending",BigDecimal.class,id))
                .isEqualByComparingTo("2.0002");
    }

    private static ReportTableResponse assetScheduleReport(FixedAssetService service,boolean deferred,int page,int size,LocalDate cutoff){
        return deferred?service.amortizationSchedule(page,size,FinanceReportColumnOptions.NONE,cutoff)
                :service.depreciationSchedule(page,size,FinanceReportColumnOptions.NONE,cutoff);
    }

    private static UUID assetScheduleMaster(boolean deferred,String code,LocalDate recognized,LocalDate closed,LocalDate reversed,boolean deleted,BigDecimal opening){
        UUID id=UUID.randomUUID();
        String lifecycle=recognized==null?"DRAFT":reversed!=null?"REVERSED":closed!=null?(deferred?"TERMINATED":"DISPOSED"):"ACTIVE";
        String status=lifecycle.equals("ACTIVE")?(deferred?"摊销中":"在用"):"停用";
        if(deferred)db.update("""
                INSERT INTO deferred_expenses(id,code,name,total_amount,useful_months,start_period,status,lifecycle_status,
                    recognized_on,terminated_on,recognition_reversed_on,is_deleted)
                VALUES(?,?,'同名待摊',1000.1234,10,'2026-01',?,?,?,?,?,?)
                """,id,code,status,lifecycle,recognized,closed,reversed,deleted);
        else db.update("""
                INSERT INTO fixed_assets(id,code,name,original_value,salvage_rate,useful_months,start_period,status,lifecycle_status,
                    capitalized_on,disposed_on,recognition_reversed_on,is_deleted,opening_as_of,opening_accumulated_amount,opening_remaining_months)
                VALUES(?,?,'同名资产',1000.1234,.05,10,'2026-01',?,?,?,?,?,?,?,?,?)
                """,id,code,status,lifecycle,recognized,closed,reversed,deleted,
                opening.signum()==0?null:LocalDate.of(2025,12,31),opening,opening.signum()==0?null:10);
        db.update(deferred?"UPDATE deferred_expenses SET expense_style_id=?,service_start_on=? WHERE id=?"
                :"UPDATE fixed_assets SET expense_style_id=?,acquired_on=? WHERE id=?",ASSET_EXPENSE,recognized,id);
        db.update("INSERT INTO finance_asset_template_metadata(object_type,object_id,valid_from,confirmed,source_reference) VALUES(?,?,?::date,true,'fixture/source')",
                deferred?"DEFERRED_EXPENSE":"FIXED_ASSET",id,recognized==null?LocalDate.of(2025,1,1):recognized);
        if(deferred)db.update("""
                INSERT INTO finance_deferral_schedule_versions(deferred_id,version,method,total_amount,useful_months,start_period,
                    status,approved_at,nominal_monthly_amount,is_deleted)
                VALUES(?,1,'STRAIGHT_LINE',1000.1234,10,'2026-01','APPROVED','2025-12-31T00:00:00Z',20.0002,false)
                """,id);
        else db.update("""
                INSERT INTO finance_asset_books(asset_id,book_type,original_value,depreciable_amount,opening_accumulated_amount,
                    useful_months,start_period,method,regular_monthly_amount,is_deleted)
                VALUES(?,'CORPORATE',1000.1234,1000.1234,?,10,'2026-01','STRAIGHT_LINE',20.0002,false)
                """,id,opening);
        return id;
    }

    /** Projection fixtures use real voucher headers and explicit fact dates; full posting workflows are tested separately. */
    private static void assetSchedulePosting(boolean deferred,UUID id,String period,String amount,String kind,String status,LocalDate voucherDate,boolean deleted){
        UUID voucher=voucherDate==null?null:UUID.randomUUID();
        if(voucher==null) {
            // An unproved legacy month keeps its exact log and month-end date,
            // but cannot masquerade as a known posted amount.
            db.update(deferred?"INSERT INTO da_amortization_log(deferred_id,period,amount,entry_kind,status,is_deleted) VALUES(?,?,?,?,?,?)"
                    :"INSERT INTO fa_depreciation_log(asset_id,period,amount,entry_kind,status,is_deleted) VALUES(?,?,?,?,?,?)",
                    id,period,new BigDecimal(amount),kind,status,deleted);
            return;
        }
        db.update("""
                INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type,status,is_deleted)
                VALUES(?,?,?,?,'AUTO',?,?,?)
                """,voucher,"REPORT-"+voucher,period,voucherDate,deferred?"DA_AMT":"FA_DEP",status.equals("REVERSED")?-1:1,deleted);
        UUID run=UUID.randomUUID(),line=UUID.randomUUID();
        UUID book=deferred?null:db.queryForObject("SELECT id FROM finance_asset_books WHERE asset_id=? AND book_type='CORPORATE'",UUID.class,id);
        db.update("INSERT INTO finance_asset_posting_runs(id,book_type,status,voucher_id,is_deleted) VALUES(?,'CORPORATE',?,?,?)",
                run,status.equals("REVERSED")?"REVERSED":"POSTED",voucher,deleted);
        db.update("""
                INSERT INTO finance_asset_posting_lines(id,run_id,fixed_asset_id,deferred_expense_id,asset_book_id,expense_style_id,
                    line_kind,amount,voucher_id,is_deleted) VALUES(?,?,?,?,?,?,?,?,?,?)
                """,line,run,deferred?null:id,deferred?id:null,book,ASSET_EXPENSE,kind,new BigDecimal(amount),voucher,deleted);
        if(deferred)db.update("""
                INSERT INTO da_amortization_log(deferred_id,period,amount,entry_kind,status,voucher_id,posting_run_id,posting_line_id,is_deleted)
                VALUES(?,?,?,?,?,?,?,?,?)
                """,id,period,new BigDecimal(amount),kind,status,voucher,run,line,deleted);
        else db.update("""
                INSERT INTO fa_depreciation_log(asset_id,period,amount,entry_kind,status,voucher_id,posting_run_id,posting_line_id,asset_book_id,is_deleted)
                VALUES(?,?,?,?,?,?,?,?,?,?)
                """,id,period,new BigDecimal(amount),kind,status,voucher,run,line,book,deleted);
        db.update("INSERT INTO gl_entries(voucher_id,style_id,direction,amount) VALUES(?,?,?,?)",voucher,ASSET_EXPENSE,
                kind.equals("REVERSAL")?-1:1,new BigDecimal(amount));
    }

    @Test void glTrialBalancePaginatesAfterTheCompleteOpeningAndPeriodAggregation() throws Exception {
        for(int index=1;index<=3;index++){
            UUID style=UUID.randomUUID();
            db.update("INSERT INTO payment_styles(id,code,name,category,level) VALUES (?,?,'同名科目','EXPENSE',0)",style,"B1-GL-"+index);
            db.update("INSERT INTO gl_entries(voucher_id,style_id,direction,amount,entry_date,period) VALUES (gen_random_uuid(),?,1,10,?,'2026-09'),(gen_random_uuid(),?,1,7,?,'2026-10'),(gen_random_uuid(),?,-1,2,?,'2026-10')",
                    style,DATE.minusMonths(1),style,DATE,style,DATE);
        }
        db.execute("INSERT INTO gl_vouchers(id,voucher_no,voucher_date,period,status,is_deleted) SELECT voucher_id,voucher_id::text,entry_date,period,1,false FROM gl_entries");
        var constructor=GlReportService.class.getConstructors()[0];
        var gl=(GlReportService)constructor.newInstance(em,mock(constructor.getParameterTypes()[1]),access);
        var first=gl.trialBalance(DATE.withDayOfMonth(1),DATE,1,1);
        assertThat(first.total()).isEqualTo(5);assertThat(first.rows()).hasSize(1);
        assertThat(first.rows().getFirst()).containsEntry("styleCode","B1-GL-1");
        assertThat((BigDecimal)first.rows().getFirst().get("openingDebit")).isEqualByComparingTo("10");
        assertThat((BigDecimal)first.rows().getFirst().get("closingDebit")).isEqualByComparingTo("15");
        var all=gl.trialBalance(DATE.withDayOfMonth(1),DATE,1,50).rows();
        assertThat(all.stream().filter(row->"DETAIL".equals(row.get("__rowKind"))).toList()).hasSize(3);
        assertThat(all.getLast()).containsEntry("__rowKind","TOTAL");
        assertThat((BigDecimal)all.getLast().get("closingDebit")).isEqualByComparingTo("45");
        executedSql.clear();
        try(var ignored=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)){
            var second=gl.trialBalance(DATE.withDayOfMonth(1),DATE,2,1);
            assertThat(second.total()).isEqualTo(-1);assertThat(second.rows().getFirst()).containsEntry("styleCode","B1-GL-2");
            assertThat((BigDecimal)second.rows().getFirst().get("openingDebit")).isEqualByComparingTo("10");
            assertThat((BigDecimal)second.rows().getFirst().get("closingDebit")).isEqualByComparingTo("15");
            assertThat(gl.trialBalance(DATE.withDayOfMonth(1),DATE,6,1).rows()).isEmpty();
        }
        assertThat(executedSql).noneSatisfy(sql->assertThat(sql).startsWith("SELECT COUNT(*)"));
        assertThat(executedSql.stream().filter(sql->sql.contains("LIMIT :__limit OFFSET :__offset")).toList())
                .hasSize(2).allSatisfy(sql->assertThat(sql).contains("GROUP BY style_id",
                        "ORDER BY report.\"__sectionOrder\",report.\"__band\",report.\"__order\",report.\"styleCode\",report.\"styleName\" LIMIT :__limit OFFSET :__offset"));
    }

    /** Actual COGS is owned by the client cost report; the original GL template has fixed rows. */
    @Test void salesCostReadsAllFiveThousandAndOneSourceGroupsAndKeepsExactTotalsTailAndPendingFacts() throws Exception {
        db.execute("INSERT INTO material_categories(id,code,name,is_deleted) SELECT gen_random_uuid(),'B1-COGS-'||n,'分类-'||lpad(n::text,5,'0'),false FROM generate_series(1,5001) n");
        db.execute("INSERT INTO goods(id,code,name,category_id,is_deleted) SELECT gen_random_uuid(),code,'分类夹具货品',id,false FROM material_categories WHERE code LIKE 'B1-COGS-%'");
        db.execute("INSERT INTO clients(id,code,name,is_deleted) SELECT gen_random_uuid(),'B1-COGS-CLIENT-'||n,'成本客户-'||lpad(n::text,5,'0'),false FROM generate_series(1,5001) n");
        db.update("""
                INSERT INTO v_stock_actual_cogs_postings(goods_id,client_id,business_date,amount_local,pending)
                SELECT goods.id,client.id,?,.1234,false FROM goods
                JOIN clients client ON client.code='B1-COGS-CLIENT-'||substring(goods.code FROM length('B1-COGS-')+1)
                WHERE goods.code LIKE 'B1-COGS-%'
                """,DATE);
        LocalDate from=DATE.withDayOfMonth(1),to=DATE.withDayOfMonth(DATE.lengthOfMonth());
        BigDecimal exactTotal=new BigDecimal(".1234").multiply(new BigDecimal("5001"));
        try(var connection=java.sql.DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword())){
            connection.setTransactionIsolation(java.sql.Connection.TRANSACTION_REPEATABLE_READ);
            connection.setReadOnly(true);connection.setAutoCommit(false);
            var cogs=new NamedParameterJdbcTemplate(new org.springframework.jdbc.datasource.SingleConnectionDataSource(connection,true));
            assertThat(cogs.queryForObject("SHOW transaction_isolation",Map.of(),String.class)).isEqualTo("repeatable read");
            assertThat(cogs.queryForObject("SHOW transaction_read_only",Map.of(),String.class)).isEqualTo("on");
            var sql=new java.util.ArrayList<String>();
            var configuration=new org.hibernate.cfg.Configuration().setProperty("hibernate.hbm2ddl.auto","none")
                    .setProperty("hibernate.connection.provider_disables_autocommit","true");
            configuration.getProperties().put("hibernate.connection.datasource",new org.springframework.jdbc.datasource.SingleConnectionDataSource(connection,true));
            configuration.setStatementInspector(statement->{sql.add(statement);return statement;});
            try(var factory=configuration.buildSessionFactory();var session=factory.openSession()) {
            session.setDefaultReadOnly(true);session.beginTransaction();
            var costs=new FinanceCostService(session,access);
            var exportSettings=mock(SystemSettingsService.class);when(exportSettings.readInt(any())).thenReturn(10_000);
            var authority=new FinanceReportService(session,access,exportSettings,mock(FinanceStatementService.class),costs,
                    mock(GlReportService.class),mock(FixedAssetService.class),mock(PartyMonthlySummaryService.class));
            var user=new com.uten.imp.security.AuthUser(UUID.randomUUID(),UUID.randomUUID(),"cogs-projection",
                    Set.of("finance_report:view","finance_report:export","finance:view:all"),false,true,false);
            org.springframework.security.core.context.SecurityContextHolder.getContext().setAuthentication(
                    new org.springframework.security.authentication.UsernamePasswordAuthenticationToken(user,null,user.getAuthorities()));
            org.springframework.transaction.support.TransactionSynchronizationManager.setActualTransactionActive(true);
            org.springframework.transaction.support.TransactionSynchronizationManager.setCurrentTransactionReadOnly(true);
            org.springframework.transaction.support.TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(java.sql.Connection.TRANSACTION_REPEATABLE_READ);
            try{
                List<com.uten.imp.common.export.ExportPayload> batches=new java.util.ArrayList<>();
                try(var sink=com.uten.imp.common.export.ExportPageSink.open(batches::add);var cursor=com.uten.imp.common.report.ReportExportCursor.open()){
                    var result=authority.export("cost/sales-summary",Map.of("dateFrom",from.toString(),"dateTo",to.toString()),null,null);
                    assertThat(result.rows()).isEmpty();
                    assertThat(result.total()).isEqualTo(5001);
                }
                assertThat(batches).extracting(batch->batch.rows().size()).containsExactly(500,500,500,500,500,500,500,500,500,500,1);
                var output=batches.stream().flatMap(batch->batch.rows().stream()).toList();
                assertThat(output).hasSize(5001);
                assertThat(output).extracting(row->row.get("clientName"))
                        .containsExactlyElementsOf(java.util.stream.IntStream.rangeClosed(1,5001)
                                .mapToObj(value->"成本客户-"+String.format("%05d",value)).toList());
                assertThat(output.stream().map(row->(BigDecimal)row.get("saleCost")).reduce(BigDecimal.ZERO,BigDecimal::add))
                        .isEqualByComparingTo(exactTotal);
                assertThat(output).allSatisfy(row->assertThat(row.get("netProfit")).isNull());
                assertThat(output.getLast().get("clientName")).isEqualTo("成本客户-05001");
                assertThat(sql.stream().filter(statement->statement.contains("ORDER BY")&&statement.contains("v_stock_actual_cogs_postings")).toList())
                        .hasSize(1).allSatisfy(statement->assertThat(statement).doesNotContain("LIMIT ? OFFSET ?"));
                var page=costs.salesCostSummary(null,from,to,2,500);
                assertThat(page.rows()).containsExactlyElementsOf(output.subList(500,1000));
                assertThat(page.total()).isEqualTo(5001);
            } finally {
                org.springframework.transaction.support.TransactionSynchronizationManager.clear();
                org.springframework.security.core.context.SecurityContextHolder.clearContext();
                session.getTransaction().rollback();
            }
            }
        }
        // The same 5001 facts remain visible when the original odd groups are
        // pending; no unknown cost becomes a known zero or a partial total.
        db.execute("UPDATE v_stock_actual_cogs_postings fact SET pending=right(goods.code,1) IN ('1','3','5','7','9') FROM goods WHERE goods.id=fact.goods_id");
        var costs=new FinanceCostService(em,access);var pendingRows=new java.util.ArrayList<Map<String,Object>>();
        try(var rowsOnly=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)) {
            for(int page=1;;page++) {
                var rows=costs.salesCostSummary(null,from,to,page,500).rows();pendingRows.addAll(rows);
                assertThat(rows).hasSizeLessThanOrEqualTo(500);if(rows.size()<500)break;
            }
        }
        assertThat(pendingRows).hasSize(5001);
        assertThat(pendingRows.stream().filter(row->row.get("saleCost")==null).count()).isEqualTo(2501);
        assertThat(pendingRows.stream().filter(row->row.get("saleCost")!=null).map(row->(BigDecimal)row.get("saleCost"))
                .reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo("308.5000");
        assertThat(db.queryForObject("SELECT sum(amount_local) FROM v_stock_actual_cogs_postings",BigDecimal.class)).isEqualByComparingTo(exactTotal);
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
