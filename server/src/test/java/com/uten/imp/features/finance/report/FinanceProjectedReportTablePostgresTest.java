package com.uten.imp.features.finance.report;

import com.uten.imp.common.web.ApiException;
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

/** Actual owning SQL over current catalog shapes; JDBC executes every submitted statement. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinanceProjectedReportTablePostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    private static final LocalDate FROM=LocalDate.of(2026,10,1),TO=LocalDate.of(2026,10,31);
    private static JdbcTemplate db;private static NamedParameterJdbcTemplate named;
    private static EntityManager em;private static FinanceReportService reports;private static FinanceStatementService statements;private static FinanceCostService costs;
    private static final UUID CLIENT=UUID.randomUUID(),SUPPLIER=UUID.randomUUID(),CURRENCY=UUID.randomUUID(),SECOND_CURRENCY=UUID.randomUUID(),UNIT=UUID.randomUUID(),SECOND_UNIT=UUID.randomUUID(),GOODS=UUID.randomUUID();
    @BeforeAll static void start(){
        PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());db=new JdbcTemplate(source);named=new NamedParameterJdbcTemplate(source);
        MigratedProjectionSchema.createCurrentTables(db,"finance_receipts","finance_receipt_lines","finance_payments","finance_payment_lines",
                "finance_expenses","finance_expense_items","finance_other_incomes","finance_other_income_items","accounts","clients","suppliers","currencies",
                "ar_ap_ledger","ar_ap_source_refs","employees","departments","payment_styles","client_director_v","sales_orders","supplier_open_item_offsets",
                "legacy_finance_import_sources","sales_shipments","sales_shipment_items","sales_returns","sales_return_items","purchase_receipts","purchase_receipt_items",
                "purchase_returns","purchase_return_items","subcontract_material_issues","subcontract_material_issue_items","subcontract_receipts","subcontract_receipt_items",
                "goods","units","colors","warehouses","stock_movements","customer_open_item_offset_batches","customer_open_item_offsets",
                "subcontract_loss_resolutions","subcontract_loss_case_lines",
                "subcontract_material_returns","subcontract_material_return_items","subcontract_returns","subcontract_return_items",
                "subcontract_wastes","subcontract_waste_items","subcontract_receipt_material_consumptions","subcontract_loss_fulfillment_allocations","stock_value_events","document_unapprovals",
                "procurement_receipt_consideration_parts","procurement_iqc_consideration_reversals",
                "finance_open_item_classification_batches","finance_open_item_classification_parts","v_finance_open_item_classification_current",
                "finance_payable_statement_adjustments","finance_payable_statement_adjustment_lines",
                "finance_receipt_classification_batches","finance_receipt_classification_parts","v_finance_receipt_classification_current",
                "finance_customer_offset_classification_batches","finance_customer_offset_classification_parts","v_finance_customer_offset_classification_current",
                "finance_sales_cost_inputs","v_finance_sales_expense_client_facts","v_finance_sales_expense_period_coverage",
                "finance_material_order_references","finance_plastic_template_inputs",
                "finance_copper_template_inputs",
                "v_stock_actual_finished_receipts","v_stock_actual_cogs_postings","v_stock_actual_sales_cost_coverage","v_workshop_material_period_report",
                "v_workshop_material_bin_ledger","workshop_material_requisition_postings","workshop_material_requisition_lines","workshop_material_requisitions",
                "workshop_material_other_issues","workshop_material_count_postings","workshop_material_count_adjustment_postings",
                "stock_documents","stock_document_items","workshop_material_close_theory_lines","workshop_material_period_closes","workshop_material_close_materials",
                "workshop_material_period_lines","workshop_material_periods","production_daily_reports","production_daily_report_items","production_execution_segments");
        MigratedProjectionSchema.createCurrentFunctions(db,"fn_business_decimal_from_integer","fn_business_exact_divide_with_policy","fn_business_exact_divide");
        em=mock(EntityManager.class);when(em.createNativeQuery(anyString())).thenAnswer(call->query(call.getArgument(0)));
        var access=mock(FinanceDocumentAccessPolicy.class);when(access.scope()).thenReturn(new OwnerScope(true,Set.of()));when(access.hasAuthority(anyString())).thenReturn(true);
        when(access.nativeReadScope(anyString(),anyString(),any(OwnerScope.class))).thenReturn(new NativeReadScope("1=1",null,Set.of()));
        var settings=mock(SystemSettingsService.class);when(settings.readInt(any())).thenReturn(500);
        statements=new FinanceStatementService(em,access);costs=new FinanceCostService(em,access);
        reports=new FinanceReportService(em,access,settings,statements,costs,mock(GlReportService.class),mock(FixedAssetService.class),mock(PartyMonthlySummaryService.class));
        db.update("INSERT INTO currencies(id,code,name) VALUES(?,'USD','同名币别'),(?,'EUR','同名币别')",CURRENCY,SECOND_CURRENCY);
        db.update("INSERT INTO clients(id,code,name) VALUES(?,'CLIENT','客户%_')",CLIENT);
        db.update("INSERT INTO suppliers(id,code,name) VALUES(?,'SUPPLIER','委外商%_')",SUPPLIER);
        db.update("INSERT INTO units(id,code,name) VALUES(?,'PCS','同名单位'),(?,'BOX','同名单位')",UNIT,SECOND_UNIT);
        db.update("INSERT INTO goods(id,code,name,unit_id) VALUES(?,'GOODS','货品%_',?)",GOODS,UNIT);
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void clean(){db.execute("TRUNCATE stock_movements,purchase_receipts,purchase_receipt_items,purchase_returns,purchase_return_items,sales_shipments,sales_shipment_items,sales_returns,sales_return_items,finance_receipts,finance_receipt_lines,finance_payments,finance_payment_lines,finance_expenses,finance_expense_items,finance_other_incomes,finance_other_income_items,ar_ap_ledger,ar_ap_source_refs,sales_orders,subcontract_material_issues,subcontract_material_issue_items,subcontract_receipts,subcontract_receipt_items,v_workshop_material_period_report,v_workshop_material_bin_ledger,workshop_material_requisition_postings,workshop_material_requisition_lines,workshop_material_requisitions,stock_documents,stock_document_items,workshop_material_close_theory_lines,workshop_material_period_closes,workshop_material_close_materials,workshop_material_period_lines,workshop_material_periods,production_daily_reports,production_daily_report_items");
        db.execute("TRUNCATE production_execution_segments");
        db.execute("TRUNCATE sales_shipments,sales_shipment_items,sales_returns,sales_return_items");
        db.update("UPDATE units SET name='同名单位'");db.update("UPDATE goods SET unit_id=? WHERE id=?",UNIT,GOODS);
    }
    @Test void clientStatementNamesFollowEachShipmentAndReturnThroughPagingFilteringAndExport() {
        UUID other=UUID.randomUUID();
        db.update("INSERT INTO clients(id,code,name) VALUES(?,?,'另一客户')",other,"OTHER-"+other);
        UUID shipment=UUID.randomUUID(),otherShipment=UUID.randomUUID(),returned=UUID.randomUUID();
        db.update("INSERT INTO sales_shipments(id,bill_no,client_id,currency_id,status,is_deleted) VALUES(?,'XC-NAME',?,?,1,false),(?,'XC-OTHER',?,?,1,false)",
                shipment,CLIENT,CURRENCY,otherShipment,other,SECOND_CURRENCY);
        db.update("INSERT INTO sales_shipment_items(id,shipment_id,goods_id,unit_id,bill_date,qty,price,amount_original,is_deleted) VALUES(?,?,?,?,?,10,2.50,25,false),(?,?,?,?,?,1,7,7,false)",
                UUID.randomUUID(),shipment,GOODS,UNIT,FROM,UUID.randomUUID(),otherShipment,GOODS,UNIT,FROM);
        db.update("INSERT INTO sales_returns(id,bill_no,client_id,currency_id,status,is_deleted) VALUES(?,'XT-NAME',?,?,1,false)",returned,CLIENT,CURRENCY);
        db.update("INSERT INTO sales_return_items(id,return_id,goods_id,unit_id,bill_date,qty,price,amount_original,is_deleted) VALUES(?,?,?,?,?,2,2.50,5,false)",
                UUID.randomUUID(),returned,GOODS,UNIT,FROM);
        var options=new FinanceReportColumnOptions(Map.of("search.clientName","客户%_"),"clientName","asc");
        var first=statements.clientStatement(null,FROM,TO,1,1,options);
        var second=statements.clientStatement(null,FROM,TO,2,1,options);
        assertThat(first.total()).isEqualTo(2);
        assertThat(first.columns()).extracting(column->column.key()).startsWith("billDate","clientName","goodsName");
        assertThat(first.columns().get(1).label()).isEqualTo("客户名称");
        assertThat(first.columnSearchKeys()).contains("clientName");
        assertThat(first.rows()).singleElement().satisfies(row->{
            assertThat(row.get("clientName")).isEqualTo("客户%_");
            assertThat((BigDecimal)row.get("qty")).isEqualByComparingTo("-2");
            assertThat((BigDecimal)row.get("amount")).isEqualByComparingTo("-5");
        });
        assertThat(second.rows()).singleElement().satisfies(row->{
            assertThat(row.get("clientName")).isEqualTo("客户%_");
            assertThat((BigDecimal)row.get("qty")).isEqualByComparingTo("10");
            assertThat((BigDecimal)row.get("amount")).isEqualByComparingTo("25");
        });
        var exported=reports.export("statements/client",Map.of("dateFrom",FROM.toString(),"dateTo",TO.toString(),
                "f.search.clientName","客户%_","sort","clientName","order","asc"),null,null);
        assertThat(exported.columns()).extracting(column->column.label()).contains("客户名称");
        assertThat(exported.rows()).hasSize(2).allSatisfy(row->assertThat(row.get("clientName")).isEqualTo("客户%_"));
        assertThat(statements.clientStatement("另一客户",FROM,TO,1,50).rows()).singleElement()
                .satisfies(row->assertThat(row.get("clientName")).isEqualTo("另一客户"));
    }
    @ParameterizedTest @ValueSource(strings={"order-plan","ar-detail","ap-detail","ar-summary","ap-summary","receipt-detail","receipt-summary","payment-detail","payment-summary","expense-detail","expense-summary","income-detail","income-summary","fee-offset"})
    void everyOrdinaryReportExecutesItsDeclaredTypedProjectionBeforeCountAndPaging(String kind){
        var initial=ordinary(kind,Map.of());var filters=new LinkedHashMap<String,String>();
        if(kind.equals("ar-summary"))assertThat(initial.columnSearchKeys()).contains("materialAmount");
        if(kind.equals("payment-detail"))assertThat(initial.columnSearchKeys()).doesNotContain("incomeItem");
        for(var column:initial.columns())if(initial.columnSearchKeys().contains(column.key()))filters.put("search."+column.key(),switch(column.type()){case "date"->"2026-10";case "money","number"->">=0";default->"literal%_";});
        if(initial.facets().containsKey("currencyCode"))filters.put("currencyCode",CURRENCY.toString());
        var result=ordinary(kind,filters);assertThat(result.rows()).isEmpty();assertThat(result.total()).isZero();
        assertThat(result.columnSearchKeys()).containsAll(initial.columnSearchKeys());assertThat(result.columns()).noneMatch(column->column.key().startsWith("__"));
    }
    @Test void supplierOriginalAndActualReversalKeepDifferentPeriodsAndFrozenNamesAndSourceAmount(){
        UUID document=UUID.randomUUID(),line=UUID.randomUUID();
        db.update("INSERT INTO purchase_receipts(id,bill_no,bill_date,supplier_id,currency_id,status,is_deleted) VALUES(?,'ANON-RECEIPT','2026-10-10',?,?,-1,false)",document,SUPPLIER,CURRENCY);
        db.update("INSERT INTO purchase_receipt_items(id,receipt_id,bill_date,goods_id,unit_id,qty,price,amount_original,goods_name_snapshot,is_deleted) VALUES(?,?,'2026-10-10',?,?,2,4,7.9999,'原始货品名',false)",line,document,GOODS,UNIT);
        db.update("INSERT INTO ar_ap_ledger(id,direction,business_type,source_doc_type,source_doc_id,bill_no,bill_date,supplier_id,currency_id,status,is_deleted,deleted_at) VALUES(?,'AP','PURCHASE','PURCHASE_RECEIPT',?,'ANON-AP','2026-10-10',?,?,-1,true,'2026-11-02T12:00:00+08:00')",UUID.randomUUID(),document,SUPPLIER,CURRENCY);
        var original=statements.supplierStatement(null,FROM,TO,SUPPLIER,CURRENCY,1,50,FinanceReportColumnOptions.NONE);
        assertThat(original.rows()).singleElement().satisfies(row->{assertThat(row.get("goodsName")).isEqualTo("原始货品名");assertThat((BigDecimal)row.get("amount")).isEqualByComparingTo("7.9999");assertThat((BigDecimal)row.get("qty")).isEqualByComparingTo("2");});
        var reversed=statements.supplierStatement(null,LocalDate.parse("2026-11-01"),LocalDate.parse("2026-11-30"),SUPPLIER,CURRENCY,1,50,FinanceReportColumnOptions.NONE);
        assertThat(reversed.rows()).singleElement().satisfies(row->{assertThat((BigDecimal)row.get("amount")).isEqualByComparingTo("-7.9999");assertThat((BigDecimal)row.get("qty")).isEqualByComparingTo("-2");assertThat(row.get("remark").toString()).contains("反审");});
    }
    @Test void unknownNativeReversalDatePreservesAPendingRowInsteadOfErasingOrInventingZero(){
        UUID document=UUID.randomUUID();db.update("INSERT INTO purchase_receipts(id,bill_no,bill_date,supplier_id,currency_id,status,is_deleted) VALUES(?,'ANON-UNKNOWN-REV','2026-10-10',?,?,-1,false)",document,SUPPLIER,CURRENCY);
        db.update("INSERT INTO purchase_receipt_items(id,receipt_id,bill_date,goods_id,unit_id,qty,price,amount_original,is_deleted) VALUES(?,?,'2026-10-10',?,?,2,4,8,false)",UUID.randomUUID(),document,GOODS,UNIT);
        var report=statements.supplierStatement(null,FROM,TO,SUPPLIER,CURRENCY,1,50,FinanceReportColumnOptions.NONE);
        assertThat(report.rows()).singleElement().satisfies(row->{assertThat(row.get("__pending")).isEqualTo(true);assertThat(row.get("amount")).isNull();assertThat(row.get("qty")).isNull();assertThat(row.get("__basis").toString()).contains("反向时间");});
        assertThat(report.totals()).anySatisfy(total->{assertThat(total.key()).isEqualTo("amount");assertThat(total.groups().getFirst().value()).isNull();});
    }
    @Test void clientActualFrozenReversalTimestampIsIndependentOfLaterHeaderUpdates(){
        UUID document=UUID.randomUUID();db.update("INSERT INTO sales_shipments(id,bill_no,bill_date,client_id,currency_id,status,is_deleted,reversed_at,updated_at) VALUES(?,'ANON-SALES','2026-10-10',?,?,-1,false,'2026-11-02T12:00:00+08:00','2026-12-01T12:00:00+08:00')",document,CLIENT,CURRENCY);
        db.update("INSERT INTO sales_shipment_items(id,shipment_id,bill_date,goods_id,unit_id,qty,price,amount_original,goods_name_snapshot,is_deleted) VALUES(?,?,'2026-10-10',?,?,2,4,7.9999,'原销售名称',false)",UUID.randomUUID(),document,GOODS,UNIT);
        var october=statements.clientStatement(null,FROM,TO,CLIENT,CURRENCY,1,50,FinanceReportColumnOptions.NONE);assertThat(october.rows()).hasSize(1);assertThat(october.rows().getFirst().get("goodsName")).isEqualTo("原销售名称");
        var november=statements.clientStatement(null,LocalDate.parse("2026-11-01"),LocalDate.parse("2026-11-30"),CLIENT,CURRENCY,1,50,FinanceReportColumnOptions.NONE);assertThat(november.rows()).hasSize(1);assertThat((BigDecimal)november.rows().getFirst().get("amount")).isEqualByComparingTo("-7.9999");
        assertThat(statements.clientStatement(null,LocalDate.parse("2026-12-01"),LocalDate.parse("2026-12-31"),CLIENT,CURRENCY,1,50,FinanceReportColumnOptions.NONE).rows()).isEmpty();
    }
    @ParameterizedTest @ValueSource(strings={"product","sales-summary","copper-fee","copper-pickling","plastic","issue","return","finished","subcontract","supplier","client","other-receivable"})
    void costAndTemplateQueriesExecuteAllActualColumnExpressionsAtTheirCompletedGrain(String kind){
        var initial=template(kind,FinanceReportColumnOptions.NONE);var filters=new LinkedHashMap<String,String>();
        if(kind.equals("sales-summary"))assertThat(initial.columnSearchKeys()).contains("manageFee","saleFee","taxFee","freight","netProfit","profitRate");
        for(var column:initial.columns())if(initial.columnSearchKeys().contains(column.key()))filters.put("search."+column.key(),switch(column.type()){case "date"->"2026-10";case "money","number"->"!=0";default->"literal%_";});
        if(initial.facets().containsKey("currencyCode"))filters.put("currencyCode",CURRENCY.toString());
        var result=template(kind,new FinanceReportColumnOptions(filters,null,null));assertThat(result.total()).isZero();assertThat(result.rows()).isEmpty();
    }
    @Test void receiptFeeAllocationAndAllTotalsAreFilteredAfterTheFullWindowAndExportUsesIdenticalConditions(){
        UUID receipt=cash("WINDOW",new BigDecimal("100"));
        for(int line=1;line<=2;line++)db.update("INSERT INTO finance_receipt_lines(id,receipt_id,line_no,currency_id,exchange_rate,amount_original,amount_local,write_off_amount,write_off_local,applied_amount_local,exchange_diff,is_deleted) VALUES(?,?,?,?,7,?,?,0,0,?,0,false)",UUID.randomUUID(),receipt,line,CURRENCY,line==1?40:60,line==1?280:420,line==1?280:420);
        var filters=Map.of("currencyCode",CURRENCY.toString(),"search.amountOriginal","=60","search.billDate","2026-10","search.clientName","客户%_");
        var result=reports.receiptDetail(null,null,null,null,FROM,TO,null,filters,1,1,null,null);
        assertThat(result.total()).isEqualTo(1);assertThat(result.rows()).singleElement().satisfies(row->{assertThat((BigDecimal)row.get("bankFee")).isEqualByComparingTo("0");assertThat(new BigDecimal(row.get("amountOriginalExact").toString())).isEqualByComparingTo("60");});
        assertThat(result.totals()).anySatisfy(total->{assertThat(total.key()).isEqualTo("bankFee");assertThat(total.groups().getFirst().value()).isZero();});
        assertThat(reports.receiptDetail(null,null,null,null,FROM,TO,null,filters,2,1,null,null).rows()).isEmpty();
        var parameters=new LinkedHashMap<String,String>();filters.forEach((key,value)->parameters.put("f."+key,value));parameters.put("dateFrom",FROM.toString());parameters.put("dateTo",TO.toString());
        var exported=reports.export("receipt/detail",parameters,null,null);assertThat(exported.rows()).hasSize(1);assertThat((BigDecimal)exported.rows().getFirst().get("bankFee")).isZero();
        assertThatThrownBy(()->reports.receiptDetail(null,null,null,null,FROM,TO,null,Map.of("search.amountOriginal","NaN"),1,10,null,null)).isInstanceOf(ApiException.class).hasMessageContaining("币别");
    }
    @Test void groupedReceiptSearchMatchesTheCompleteCustomerCurrencySubtotal(){
        cash("SUM-A",new BigDecimal("40"));cash("SUM-B",new BigDecimal("30"));
        var result=reports.receiptSummary(null,null,null,FROM,TO,null,1,1,Map.of("currencyCode",CURRENCY.toString(),"search.amountTotal",">=60"),"amountTotal","desc");
        assertThat(result.total()).isEqualTo(1);assertThat((BigDecimal)result.rows().getFirst().get("amountTotal")).isEqualByComparingTo("70");
        assertThat(((Number)result.rows().getFirst().get("receiptCount")).longValue()).isEqualTo(2);
    }
    @Test void subcontractCurrenciesAndUnitsKeepPhysicalContextAndNeverInventMaterialPrices(){
        issue(UNIT,"100","0","2026-10-01");issue(SECOND_UNIT,"20","0","2026-10-01");
        receipt(UNIT,CURRENCY,"10","2","2026-10-10");receipt(UNIT,SECOND_CURRENCY,"5","3","2026-10-11");receipt(SECOND_UNIT,CURRENCY,"2","4","2026-10-12");
        receipt(UNIT,CURRENCY,"1","0","2026-10-28");receipt(UNIT,CURRENCY,"1","999","2026-11-01");
        var full=statements.subcontractStatement(null,FROM,TO,null,1,50);assertThat(full.rows()).hasSize(3);assertThat(full.totals()).isEmpty();
        var filtered=statements.subcontractStatement(null,FROM,TO,null,1,1,new FinanceReportColumnOptions(Map.of("currencyCode",SECOND_CURRENCY.toString(),"search.processAmount","15"),null,null));
        assertThat(filtered.total()).isEqualTo(1);var row=filtered.rows().getFirst();
        assertThat((BigDecimal)row.get("issueQty")).isEqualByComparingTo("100");assertThat((BigDecimal)row.get("receiptQty")).isEqualByComparingTo("16");assertThat((BigDecimal)row.get("balance")).isEqualByComparingTo("81");
        assertThat((BigDecimal)row.get("processQty")).isEqualByComparingTo("5");assertThat(row.get("materialPrice")).isNull();assertThat(row.get("materialAmount")).isNull();
        assertThat(full.rows()).anySatisfy(value->{assertThat(value.get("__currencyId")).isEqualTo(CURRENCY.toString());assertThat(value.get("__unitId")).isEqualTo(UNIT.toString());assertThat(value.get("processPrice")).isNull();assertThat((BigDecimal)value.get("processAmount")).isEqualByComparingTo("20");});
        assertThat(full.rows().stream().map(value->value.get("__physicalGroupKey")).distinct()).hasSize(2);
        assertThat(costs.copperFee(null,FROM,TO,1,50).rows()).hasSize(4);
    }
    @Test void subcontractUsesTheOriginalTransactionAmountsAndNeverRepricesTheMonthAtItsLastPrice(){
        issue(UNIT,"100","0","2026-10-01");
        receipt(UNIT,CURRENCY,"10","2","2026-10-10");
        receipt(UNIT,CURRENCY,"10","3","2026-10-11");
        db.update("UPDATE subcontract_receipt_items SET amount_original=29.9999 WHERE price=3");
        var row=statements.subcontractStatement(null,FROM,TO,null,1,50).rows().getFirst();
        assertThat((BigDecimal)row.get("processQty")).isEqualByComparingTo("20");
        assertThat(row.get("processPrice")).isNull();
        assertThat((BigDecimal)row.get("processAmount")).isEqualByComparingTo("49.9999");
        db.update("UPDATE subcontract_receipt_items SET amount_original=NULL WHERE price=3");
        assertThat(statements.subcontractStatement(null,FROM,TO,null,1,50).rows().getFirst().get("processAmount")).isNull();
    }
    @Test void originalNineteenColumnSubcontractZipsSourcesWithoutMultiplicationAndNeverLabelsBoxesAsPcs(){
        issue(UNIT,"10","0","2026-09-30");receipt(UNIT,CURRENCY,"2","2","2026-09-30");
        issue(UNIT,"100","0","2026-10-01");issue(UNIT,"50","0","2026-10-02");issue(UNIT,"25","0","2026-10-03");
        receipt(UNIT,CURRENCY,"10","2","2026-10-10");receipt(UNIT,CURRENCY,"20","3","2026-10-11");
        var result=statements.subcontractStatement("GOODS",FROM,TO,null,SUPPLIER,CURRENCY,1,50,FinanceReportColumnOptions.NONE);
        assertThat(result.columns()).hasSize(19);assertThat(result.rows()).hasSize(3);
        assertThat(result.rows().stream().map(r->r.get("__issueItemId")).distinct()).hasSize(3);
        assertThat(result.rows().stream().filter(r->r.get("__receiptItemId")!=null).map(r->r.get("__receiptItemId")).distinct()).hasSize(2);
        var first=result.rows().getFirst();assertThat((BigDecimal)first.get("prevStock")).isEqualByComparingTo("8");
        assertThat((BigDecimal)first.get("issueTotalQty")).isEqualByComparingTo("175");
        assertThat((BigDecimal)first.get("receiptTotalQty")).isEqualByComparingTo("30");
        assertThat((BigDecimal)first.get("balance")).isEqualByComparingTo("147.75");
        assertThat(result.rows().stream().map(r->(BigDecimal)r.get("processAmount")).filter(Objects::nonNull).reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo("80");
        issue(SECOND_UNIT,"20","0","2026-10-04");
        var boxes=statements.subcontractStatement(null,FROM,TO,null,SUPPLIER,CURRENCY,1,50,FinanceReportColumnOptions.NONE).rows().stream()
                .filter(r->SECOND_UNIT.toString().equals(r.get("__unitId"))).findFirst().orElseThrow();
        assertThat(boxes.get("issueQty")).isNull();assertThat(boxes.get("balance")).isNull();assertThat(boxes.get("__pending")).isEqualTo(true);
    }
    @Test void originalAllowedLossFormulaKeepsItsCompleteProductInsteadOfRoundingTheoreticalQuantityToMoneyCents(){
        issue(UNIT,"1.2345","0","2026-10-01");
        var original=statements.subcontractStatement(null,FROM,TO,null,SUPPLIER,CURRENCY,1,50,FinanceReportColumnOptions.NONE).rows().getFirst();
        assertThat((BigDecimal)original.get("lossAllowed")).isEqualByComparingTo("0.037035");assertThat((BigDecimal)original.get("balance")).isEqualByComparingTo("1.197465");
        var legacy=statements.subcontractStatement(null,FROM,TO,null,1,50).rows().getFirst();assertThat((BigDecimal)legacy.get("lossAllowed")).isEqualByComparingTo("0.037035");
    }
    @Test void prepaymentHeadersAndTheNewExportKeepExactCurrencyIdentityAndOriginalEventFacts(){
        UUID target=cash("PREPAY-TARGET",BigDecimal.TEN),other=cash("PREPAY-OTHER",BigDecimal.TEN);
        db.update("UPDATE finance_receipts SET receipt_kind='CUSTOMER_PREPAYMENT',amount_original=90071992547409.1234,amount_local=90071992547409.1234,exchange_rate=1,remark='精确%_历史事实' WHERE id IN (?,?)",target,other);
        db.update("UPDATE finance_receipts SET currency_id=? WHERE id=?",SECOND_CURRENCY,other);
        var filters=Map.of("currencyCode",CURRENCY.toString(),"search.prepaymentCashOriginal",">=90071992547409.1234",
                "search.eventDate","2026-10","search.reason","精确%_","search.eventTypeLabel","预收到账");
        var result=reports.customerPrepaymentEvents(CLIENT,FROM,TO,1,1,"PREPAY TARGET",new FinanceReportColumnOptions(filters,null,null));
        assertThat(result.total()).isEqualTo(1);assertThat(result.rows()).singleElement().satisfies(row->{
            assertThat(row.get("eventNo")).isEqualTo("PREPAY-TARGET");
            assertThat(new BigDecimal(row.get("prepaymentCashOriginalExact").toString())).isEqualByComparingTo("90071992547409.1234");
            assertThat(row).containsKey("salesOrderIds");assertThat(row).doesNotContainKey("__salesOrderIds");
        });
        assertThat(result.columns()).noneMatch(column->column.key().startsWith("__"));
        var parameters=new LinkedHashMap<String,String>();filters.forEach((key,value)->parameters.put("f."+key,value));
        parameters.put("dateFrom",FROM.toString());parameters.put("dateTo",TO.toString());parameters.put("keyword","PREPAY TARGET");
        assertThat(reports.export("customer-prepayment/events",parameters,null,null).rows()).hasSize(1);
    }
    @Test void copperBalanceSearchKeepsPriorRowsAndDoesNotInventAnUnverifiedMaterialCurrency(){
        receipt(UNIT,CURRENCY,"3","2","2026-10-01");db.update("UPDATE subcontract_receipt_items SET weight=10");
        issue(UNIT,"5","5","2026-10-02");
        var result=statements.otherReceivableStatement(null,FROM,TO,1,1,new FinanceReportColumnOptions(Map.of("search.billNo","ISS","search.balance","4.95"),null,null));
        assertThat(result.total()).isEqualTo(1);var row=result.rows().getFirst();
        assertThat((BigDecimal)row.get("balance")).isEqualByComparingTo("4.95");assertThat((BigDecimal)row.get("outQty")).isEqualByComparingTo("5");
        assertThat(row.get("unit")).isEqualTo("同名单位");assertThat(row.get("price")).isNull();assertThat(row.get("processAmount")).isNull();
        assertThatThrownBy(()->statements.otherReceivableStatement(null,FROM,TO,1,1,new FinanceReportColumnOptions(Map.of(),"balance","desc")))
                .isInstanceOf(ApiException.class).hasMessageContaining("时间");
    }
    @Test void costMaterialUnitsUsePostingAndPeriodSnapshotsWhileUnprovedProductBaseUnitsStayUnknown(){
        UUID bin=UUID.randomUUID(),document=UUID.randomUUID(),item=UUID.randomUUID(),request=UUID.randomUUID(),line=UUID.randomUUID(),posting=UUID.randomUUID();
        db.update("UPDATE units SET name='历史千克' WHERE id=?",UNIT);db.update("UPDATE units SET name='当前件' WHERE id=?",SECOND_UNIT);
        db.update("UPDATE goods SET unit_id=? WHERE id=?",SECOND_UNIT,GOODS);
        db.update("INSERT INTO warehouses(id,name) VALUES(?,'原料仓')",bin);
        db.update("INSERT INTO stock_documents(id,bill_no,bill_date) VALUES(?,'MATERIAL-DOC',?)",document,FROM);
        db.update("INSERT INTO stock_document_items(id,doc_id) VALUES(?,?)",item,document);
        db.update("INSERT INTO workshop_material_requisitions(id,request_no) VALUES(?,'REQ-UNIT')",request);
        db.update("INSERT INTO workshop_material_requisition_lines(id,requisition_id,unit_id) VALUES(?,?,?)",line,request,UNIT);
        db.update("INSERT INTO workshop_material_requisition_postings(id,line_id,stock_document_item_id) VALUES(?,?,?)",posting,line,item);
        db.update("INSERT INTO v_workshop_material_bin_ledger(source_kind,source_row_id,business_date,goods_id,bin_warehouse_id,signed_qty,is_supplement) VALUES('ISSUE',?,?,?,?,2,false)",posting,FROM,GOODS,bin);
        var issue=costs.plasticDetail("issue",null,FROM,TO,1,10,new FinanceReportColumnOptions(Map.of("search.unit","历史千克","search.qty","2"),null,null));
        assertThat(issue.total()).isEqualTo(1);assertThat(issue.rows().getFirst().get("unit")).isEqualTo("历史千克");
        UUID period=UUID.randomUUID(),periodLine=UUID.randomUUID(),close=UUID.randomUUID(),material=UUID.randomUUID(),theory=UUID.randomUUID(),report=UUID.randomUUID(),reportItem=UUID.randomUUID(),segment=UUID.randomUUID();
        db.update("INSERT INTO workshop_material_periods(id,bin_warehouse_id,start_date,end_date) VALUES(?,?,?,?)",period,bin,FROM,TO);
        db.update("INSERT INTO workshop_material_period_lines(id,period_id,goods_id,unit_id) VALUES(?,?,?,?)",periodLine,period,GOODS,UNIT);
        db.update("INSERT INTO workshop_material_period_closes(id,period_id,status) VALUES(?,?,'ACTIVE')",close,period);
        db.update("INSERT INTO workshop_material_close_materials(id,period_line_id) VALUES(?,?)",material,periodLine);
        db.update("INSERT INTO production_daily_reports(id,bill_no) VALUES(?,'REPORT-UNIT')",report);
        db.update("INSERT INTO production_daily_report_items(id,report_id,unit_id,unit_rate,qty) VALUES(?,?,?,2,1.5)",reportItem,report,SECOND_UNIT);
        db.update("INSERT INTO production_execution_segments(id,product_goods_id,product_unit_id,product_unit_rate) VALUES(?,?,?,2)",segment,GOODS,SECOND_UNIT);
        db.update("INSERT INTO workshop_material_close_theory_lines(id,close_id,close_material_id,report_id,report_item_id,product_goods_id,business_date,execution_segment_id,theory_qty,output_qty_base) VALUES(?,?,?,?,?,?,?,?,2,3)",theory,close,material,report,reportItem,GOODS,FROM,segment);
        var output=costs.plasticDetail("finished",null,FROM,TO,1,10);assertThat(output.rows()).hasSize(1);
        assertThat(output.rows().getFirst().get("materialUnit")).isNull();assertThat(output.rows().getFirst().get("weight")).isNull();assertThat(output.rows().getFirst().get("productUnit")).isNull();
        db.update("UPDATE production_execution_segments SET product_unit_rate=1 WHERE id=?",segment);
        db.update("UPDATE production_daily_report_items SET unit_rate=1,qty=3 WHERE id=?",reportItem);
        db.update("UPDATE goods SET unit_id=? WHERE id=?",UNIT,GOODS);
        assertThat(costs.plasticDetail("finished",null,FROM,TO,1,10).rows().getFirst().get("productUnit")).isEqualTo("当前件");
        db.update("""
                INSERT INTO v_workshop_material_period_report(bin_warehouse_id,goods_id,unit_id,period_line_id,close_id,start_date,end_date,period_no,cost_basis,
                    opening_qty,transfer_in_qty,return_qty,other_issue_qty,theory_qty,closing_qty,actual_qty)
                VALUES(?,?,?,?,?,?,?,1,'OWN',1,2,0,0,1,2,1)
                """,bin,GOODS,UNIT,periodLine,close,FROM,TO);
        var usage=costs.plasticUsage(null,FROM,TO,1,10);
        assertThat(usage.rows()).hasSize(1);assertThat(usage.rows().getFirst().get("rejectQty")).isNull();
        assertThat(usage.columnSearchKeys()).doesNotContain("rejectQty");
    }
    @Test void unknownCopperWeightsRemainEventsAndMakeSubsequentBalancesUnknownAcrossTheOpeningBoundary(){
        receipt(UNIT,CURRENCY,"3","2","2026-09-30");
        issue(UNIT,"5","5","2026-10-02");
        var carried=statements.otherReceivableStatement(null,FROM,TO,1,10);
        assertThat(carried.total()).isEqualTo(1);assertThat(carried.rows().getFirst().get("balance")).isNull();
        receipt(UNIT,CURRENCY,"2","2","2026-10-01");
        var period=statements.otherReceivableStatement(null,FROM,TO,1,10);
        assertThat(period.total()).isEqualTo(2);
        assertThat(period.rows()).anySatisfy(row->{assertThat(row.get("inWeight")).isNull();assertThat((BigDecimal)row.get("outWeight")).isZero();assertThat(row.get("loss")).isNull();});
        assertThat(period.rows()).allSatisfy(row->assertThat(row.get("balance")).isNull());
        var issueOnly=statements.otherReceivableStatement(null,FROM,TO,1,10,new FinanceReportColumnOptions(Map.of("search.billNo","ISS"),null,null));
        assertThat(issueOnly.total()).isEqualTo(1);assertThat(issueOnly.rows().getFirst().get("balance")).isNull();
        assertThat(period.columnSearchKeys()).doesNotContain("price","processAmount");
        assertThatThrownBy(()->statements.otherReceivableStatement(null,FROM,TO,1,10,new FinanceReportColumnOptions(Map.of("search.price","NaN"),null,null)))
                .isInstanceOf(ApiException.class).hasMessageContaining("尚无可检索");
    }
    @Test void unprovedNullUnitRowsKeepSourceEvidenceWithoutCombiningQuantitiesOrPrices(){
        issue(null,"10","0","2026-10-01");receipt(null,CURRENCY,"2","100","2026-10-02");receipt(null,CURRENCY,"3","200","2026-10-03");
        var result=statements.subcontractStatement(null,FROM,TO,null,1,20);assertThat(result.total()).isEqualTo(1);var row=result.rows().getFirst();
        for(String field:List.of("prevStock","issueQty","lossAllowed","receiptQty","balance","processQty","processPrice","processAmount"))assertThat(row.get(field)).as(field).isNull();
        assertThat(row.get("issueBillNo").toString()).contains("ISS-");
        for(String bill:db.queryForList("SELECT bill_no FROM subcontract_receipts",String.class))assertThat(row.get("receiptBillNo").toString()).contains(bill);
        assertThat(row.get("receiptDate")).isNotNull();assertThat(row.get("unit")).isNull();
        assertThat(result.columnSearchKeys()).doesNotContain("materialPrice","materialAmount");
        var copper=costs.copperFee(null,FROM,TO,1,20);assertThat(copper.total()).isEqualTo(2);
        for(var copperRow:copper.rows())for(String field:List.of("qty","price","amount"))assertThat(copperRow.get(field)).as("unproved copper "+field).isNull();
        for(String bill:db.queryForList("SELECT bill_no FROM subcontract_receipts",String.class))assertThat(copper.rows()).anySatisfy(value->assertThat(value.get("sourceBillNos").toString()).contains(bill));
        assertThatThrownBy(()->statements.subcontractStatement(null,FROM,TO,null,1,20,new FinanceReportColumnOptions(Map.of(),"materialAmount","asc")))
                .isInstanceOf(ApiException.class).hasMessageContaining("尚无可检索");
        db.update("UPDATE subcontract_material_issue_items SET unit_rate=1");db.update("UPDATE subcontract_receipt_items SET unit_rate=1");
        assertThat(statements.subcontractStatement(null,FROM,TO,null,1,20).rows().getFirst().get("issueQty")).isNull();
        db.update("UPDATE subcontract_material_issue_items SET unit_id=?",UNIT);db.update("UPDATE subcontract_receipt_items SET unit_id=?",UNIT);
        var proved=statements.subcontractStatement(null,FROM,TO,null,1,20).rows().getFirst();
        assertThat(proved.get("__unitId")).isEqualTo(UNIT.toString());assertThat((BigDecimal)proved.get("issueQty")).isEqualByComparingTo("10");
        assertThat((BigDecimal)proved.get("receiptQty")).isEqualByComparingTo("5");
        assertThat(costs.copperFee(null,FROM,TO,1,20).rows().stream().map(value->(BigDecimal)value.get("qty")).reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo("5");
    }
    private static ReportTableResponse ordinary(String kind,Map<String,String> filters){return switch(kind){
        case "order-plan"->reports.salesOrderReceivablePlan(null,null,FROM,TO,null,1,1,null,null,filters);
        case "ar-detail","ap-detail"->reports.arApDetail(kind.startsWith("ar")?"AR":"AP",null,null,null,FROM,TO,null,filters,1,1,null,null);
        case "ar-summary","ap-summary"->reports.arApSummary(kind.startsWith("ar")?"AR":"AP",FROM,TO,null,1,1,filters,null,null);
        case "receipt-detail"->reports.receiptDetail(null,null,null,null,FROM,TO,null,filters,1,1,null,null);
        case "receipt-summary"->reports.receiptSummary(null,null,null,FROM,TO,null,1,1,filters,null,null);
        case "payment-detail"->reports.paymentDetail(null,null,null,null,FROM,TO,null,filters,1,1,null,null);
        case "payment-summary"->reports.paymentSummary(null,null,null,FROM,TO,null,filters,1,1,null,null);
        case "expense-detail"->reports.expenseDetail(null,null,null,null,FROM,TO,null,filters,1,1,null,null);
        case "expense-summary"->reports.expenseSummary(null,null,null,FROM,TO,null,filters,1,1,null,null);
        case "income-detail"->reports.incomeDetail(null,null,null,null,FROM,TO,null,filters,1,1,null,null);
        case "income-summary"->reports.incomeSummary(null,null,null,FROM,TO,null,filters,1,1,null,null);
        default->reports.feeOffsetDetail(null,null,null,null,FROM,TO,null,filters,1,1,null,null);
    };}
    private static ReportTableResponse template(String kind,FinanceReportColumnOptions options){return switch(kind){
        case "product"->costs.productCost(null,FROM,TO,1,1,options);case "sales-summary"->costs.salesCostSummary(null,FROM,TO,1,1,options);
        case "copper-fee"->costs.copperFee(null,FROM,TO,1,1,options);case "copper-pickling"->costs.copperPickling(null,FROM,TO,1,1,options);
        case "plastic"->costs.plasticUsage(null,FROM,TO,1,1,options);case "issue","return","finished"->costs.plasticDetail(kind,null,FROM,TO,1,1,options);
        case "subcontract"->statements.subcontractStatement(null,FROM,TO,null,1,1,options);case "supplier"->statements.supplierStatement(null,FROM,TO,1,1,options);
        case "client"->statements.clientStatement(null,FROM,TO,1,1,options);default->statements.otherReceivableStatement(null,FROM,TO,1,1,options);
    };}
    private static UUID cash(String no,BigDecimal amount){UUID id=UUID.randomUUID();db.update("INSERT INTO finance_receipts(id,bill_no,bill_date,client_id,currency_id,amount_original,amount_local,exchange_rate,bank_fee,other_fee,status,is_deleted) VALUES(?,?,? ,?,?,?,?*7,7,9,2,1,false)",id,no,FROM,CLIENT,CURRENCY,amount,amount);return id;}
    private static void issue(UUID unit,String quantity,String weight,String date){UUID id=UUID.randomUUID();db.update("INSERT INTO subcontract_material_issues(id,bill_no,bill_date,supplier_id,status,is_deleted) VALUES(?,?,?::date,?,1,false)",id,"ISS-"+id,date,SUPPLIER);db.update("INSERT INTO subcontract_material_issue_items(id,issue_id,bill_no,bill_date,goods_id,unit_id,qty,weight,price,wasted_qty,is_deleted) VALUES(?,?,?,?::date,?,?,?::numeric,?::numeric,99,0,false)",UUID.randomUUID(),id,"ISS-"+id,date,GOODS,unit,quantity,weight);}
    private static void receipt(UUID unit,UUID currency,String quantity,String price,String date){UUID id=UUID.randomUUID();db.update("INSERT INTO subcontract_receipts(id,bill_no,bill_date,supplier_id,currency_id,status,is_deleted) VALUES(?,?,?::date,?,?,1,false)",id,"RCV-"+id,date,SUPPLIER,currency);db.update("INSERT INTO subcontract_receipt_items(id,receipt_id,bill_no,bill_date,goods_id,unit_id,qty,price,amount_original,is_deleted) VALUES(?,?,?,?::date,?,?,?::numeric,?::numeric,?::numeric,false)",UUID.randomUUID(),id,"RCV-"+id,date,GOODS,unit,quantity,price,new BigDecimal(quantity).multiply(new BigDecimal(price)));}
    private static Query query(String sql){Query query=mock(Query.class);var parameters=new LinkedHashMap<String,Object>();when(query.setParameter(anyString(),any())).thenAnswer(call->{parameters.put(call.getArgument(0),call.getArgument(1));return query;});when(query.getResultList()).thenAnswer(call->named.query(sql,parameters,(rs,index)->{Object[] row=new Object[rs.getMetaData().getColumnCount()];for(int i=0;i<row.length;i++) { row[i]=rs.getObject(i+1); } return row;}));when(query.getSingleResult()).thenAnswer(call->named.queryForObject(sql,parameters,Long.class));return query;}
}
