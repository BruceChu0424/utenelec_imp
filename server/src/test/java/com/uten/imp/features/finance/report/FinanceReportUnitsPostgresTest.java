package com.uten.imp.features.finance.report;

import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
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
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    private static final UUID CLIENT=UUID.randomUUID(),SUPPLIER=UUID.randomUUID(),CURRENCY=UUID.randomUUID(),ACCOUNT=UUID.randomUUID();
    private static final LocalDate DATE=LocalDate.of(2026,10,12);
    private static JdbcTemplate db;
    private static NamedParameterJdbcTemplate named;
    private static FinanceReportService reports;
    private static List<String> dataColumns=List.of();

    @BeforeAll static void start(){
        PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(source);named=new NamedParameterJdbcTemplate(source);
        MigratedProjectionSchema.createCurrentTables(db,"finance_receipts","finance_receipt_lines","finance_payments",
                "finance_expenses","finance_expense_items","finance_other_incomes","finance_other_income_items",
                "finance_reconciliations","account_flow_monthly_summaries","ar_ap_ledger","ar_ap_source_refs","accounts","clients","suppliers",
                "currencies","employees","departments","payment_styles","client_director_v","client_categories","supplier_categories","sales_orders",
                "sales_order_items","sales_shipments","sales_shipment_items","customer_open_item_offset_batches","customer_open_item_offsets");
        EntityManager em=mock(EntityManager.class);when(em.createNativeQuery(anyString())).thenAnswer(call->query(call.getArgument(0)));
        var access=mock(FinanceDocumentAccessPolicy.class);when(access.scope()).thenReturn(new OwnerScope(true,Set.of()));
        when(access.hasAuthority(anyString())).thenReturn(true);
        when(access.nativeReadScope(anyString(),anyString(),any(OwnerScope.class))).thenReturn(new NativeReadScope("1=1",null,Set.of()));
        reports=new FinanceReportService(em,access,mock(SystemSettingsService.class),mock(FinanceStatementService.class),
                mock(FinanceCostService.class),mock(GlReportService.class),mock(FixedAssetService.class));
        db.update("INSERT INTO currencies(id,name,code) VALUES (?,'美金','002')",CURRENCY);
        db.update("INSERT INTO clients(id,code,name) VALUES (?,'CLIENT','客户名')",CLIENT);
        db.update("INSERT INTO suppliers(id,code,name) VALUES (?,'SUPPLIER','供应商名')",SUPPLIER);
        db.update("INSERT INTO accounts(id,name,currency_id,init_balance) VALUES (?,'美元账户',?,3)",ACCOUNT,CURRENCY);
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void reset(){db.execute("TRUNCATE finance_receipts,finance_receipt_lines,finance_payments,finance_expenses,finance_expense_items,finance_other_incomes,finance_other_income_items,finance_reconciliations,ar_ap_ledger");}
    private static Query query(String sql){
        Query query=mock(Query.class);Map<String,Object> parameters=new LinkedHashMap<>();
        when(query.setMaxResults(anyInt())).thenReturn(query);
        when(query.setParameter(anyString(),any())).thenAnswer(call->{parameters.put(call.getArgument(0),call.getArgument(1));return query;});
        when(query.getResultList()).thenAnswer(call->named.query(sql,parameters,(rs,index)->{
            Object[] row=new Object[rs.getMetaData().getColumnCount()];var aliases=new java.util.ArrayList<String>();
            for(int i=0;i<row.length;i++){row[i]=rs.getObject(i+1);aliases.add(rs.getMetaData().getColumnLabel(i+1));}
            if(sql.contains("LIMIT :__limit OFFSET :__offset")){ dataColumns=List.copyOf(aliases); }return row;
        }));
        when(query.getSingleResult()).thenAnswer(call->named.queryForObject(sql,parameters,Long.class));return query;
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
            case "RECEIPT"->reports.receiptSummary("REPORT-RECEIPT",null,null,null,null,null,Map.of(),1,50,null,null);
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
}
