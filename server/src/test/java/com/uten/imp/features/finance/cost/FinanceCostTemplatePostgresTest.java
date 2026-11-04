package com.uten.imp.features.finance.cost;

import com.uten.imp.features.finance.*;
import com.uten.imp.features.finance.report.*;
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

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinanceCostTemplatePostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    static JdbcTemplate db;static NamedParameterJdbcTemplate named;static FinanceCostService reports;
    static final UUID CLIENT=UUID.randomUUID(),SUPPLIER=UUID.randomUUID(),GOODS=UUID.randomUUID(),UNIT=UUID.randomUUID(),CURRENCY=UUID.randomUUID();
    static final LocalDate FROM=LocalDate.of(2026,9,1),TO=LocalDate.of(2026,9,30);
    @BeforeAll static void setup() {
        PG.start();var ds=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());db=new JdbcTemplate(ds);named=new NamedParameterJdbcTemplate(ds);
        MigratedProjectionSchema.createCurrentTables(db,"clients","employees","client_director_v","currencies","suppliers","goods","units",
                "subcontract_receipts","subcontract_receipt_items","ar_ap_ledger","v_stock_actual_cogs_postings","v_stock_actual_sales_cost_coverage",
                "finance_sales_cost_inputs","v_finance_sales_expense_client_facts","v_finance_sales_expense_period_coverage",
                "v_workshop_material_period_report","finance_plastic_template_inputs","warehouses","colors");
        // The exact-ratio columns call the real migrated precision functions; without them the
        // class-42 "function does not exist" surfaces as Spring bad SQL grammar.
        MigratedProjectionSchema.createCurrentFunctions(db,"fn_business_decimal_from_integer",
                "fn_business_exact_divide_with_policy","fn_business_exact_divide");
        EntityManager em=mock(EntityManager.class);when(em.createNativeQuery(anyString())).thenAnswer(c->query(c.getArgument(0)));
        var access=mock(FinanceDocumentAccessPolicy.class);when(access.hasAuthority(anyString())).thenReturn(true);when(access.scope()).thenReturn(new OwnerScope(true,Set.of()));
        reports=new FinanceCostService(em,access);
        db.update("INSERT INTO clients(id,code,name,is_deleted) VALUES(?,'C','匿名客户',false)",CLIENT);
        db.update("INSERT INTO suppliers(id,code,name,is_deleted) VALUES(?,'S','匿名加工商',false)",SUPPLIER);
        db.update("INSERT INTO goods(id,code,name,unit_id,is_deleted) VALUES(?,'G','匿名铜柱',?,false)",GOODS,UNIT);
        db.update("INSERT INTO units(id,code,name,is_deleted) VALUES(?,'U','个',false)",UNIT);
        db.update("INSERT INTO currencies(id,code,name,is_deleted) VALUES(?,'RMB','人民币',false)",CURRENCY);
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void clean(){db.execute("TRUNCATE subcontract_receipts,subcontract_receipt_items,ar_ap_ledger,v_stock_actual_cogs_postings,v_stock_actual_sales_cost_coverage,finance_sales_cost_inputs,v_finance_sales_expense_client_facts,v_workshop_material_period_report,finance_plastic_template_inputs");}
    @Test void confirmedPlasticRatioUsesSettledConsumptionAndPreservesDirectionsUnitsAndUnknownDenominator() {
        UUID line=UUID.randomUUID(),close=UUID.randomUUID(),bin=UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name) VALUES(?,?,'匿名内料仓')",bin,"BIN-"+bin);
        db.update("INSERT INTO v_workshop_material_period_report(bin_warehouse_id,goods_id,unit_id,period_line_id,close_id,start_date,end_date,period_no,cost_basis,opening_qty,transfer_in_qty,return_qty,other_issue_qty,theory_qty,closing_qty,actual_qty) VALUES(?,?,?,?,?,?,?,1,'OWN',100,20,10,5,80,5,100)",bin,GOODS,UNIT,line,close,FROM,TO);
        db.update("INSERT INTO finance_plastic_template_inputs(period_line_id,source_close_id,source_unit_id,weight_kg_per_unit,reject_return_qty,reject_issue_qty,reason,confirmed) VALUES(?,?,?,.5,2,5,'已核对匿名盘点差异',true)",line,close,UNIT);
        var row=reports.plasticUsage(null,FROM,TO,1,50,FinanceReportColumnOptions.NONE,bin).rows().getFirst();
        amount(row,"usageRatio","80");amount(row,"returnQty","4");amount(row,"rejectReturnQty","1");amount(row,"rejectIssueQty","2.5");
        amount(row,"finishedWeight","40");amount(row,"bookBalance","12.5");amount(row,"checkQty","2.5");amount(row,"diff","-10");
        assertThat(row.get("unit")).isEqualTo("KG");assertThat(row.get("__pending")).isEqualTo(false);
        db.update("UPDATE v_workshop_material_period_report SET actual_qty=0");
        assertThat(reports.plasticUsage(null,FROM,TO,1,50,FinanceReportColumnOptions.NONE,bin).rows().getFirst().get("usageRatio")).isNull();
        db.update("UPDATE v_workshop_material_period_report SET actual_qty=NULL,close_id=gen_random_uuid()");
        row=reports.plasticUsage(null,FROM,TO,1,50,FinanceReportColumnOptions.NONE,bin).rows().getFirst();
        assertThat(row.get("usageRatio")).isNull();assertThat(row.get("finishedWeight")).isNull();assertThat(row.get("__pending")).isEqualTo(true);
    }
    @Test void copperUsesOriginalPriceGroupsAndMoneyInsteadOfLatestPriceTimesAllQuantity() {
        UUID receipt=UUID.randomUUID();db.update("INSERT INTO subcontract_receipts(id,bill_no,status,supplier_id,currency_id,is_deleted) VALUES(?,'R',1,?,?,false)",receipt,SUPPLIER,CURRENCY);
        for(String[] values:new String[][]{{"10","2","20"},{"10","3","30"}})db.update("INSERT INTO subcontract_receipt_items(id,receipt_id,bill_no,bill_date,goods_id,unit_id,qty,price,amount_original,is_deleted) VALUES(gen_random_uuid(),?,'R','2026-09-02',?,?,?,?,?,false)",receipt,GOODS,UNIT,new BigDecimal(values[0]),new BigDecimal(values[1]),new BigDecimal(values[2]));
        var report=reports.copperFee(null,FROM,TO,1,50,FinanceReportColumnOptions.NONE,SUPPLIER);
        assertThat(report.columns()).extracting(ReportColumn::label).containsExactly("序号","产品名称","单位","数量","单价","金额");
        assertThat(report.rows()).hasSize(2);
        assertThat(report.rows().stream().map(r->(BigDecimal)r.get("amount")).reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo("50");
        assertThat(report.rows()).allSatisfy(r->assertThat((BigDecimal)r.get("qty")).isEqualByComparingTo("10"));
        db.update("UPDATE subcontract_receipt_items SET amount_original=NULL WHERE price=3");
        assertThat(reports.copperFee(null,FROM,TO,1,50,FinanceReportColumnOptions.NONE,SUPPLIER).rows()).anySatisfy(r->{assertThat(r.get("amount")).isNull();assertThat(r.get("__pending")).isEqualTo(true);});
    }
    @Test void sourceTaxApplicabilityAndChannelsAreExplicitAndConfirmedZeroIsNotUnknown() {
        revenue("1000");cost("600");input("OEM","0","5");
        var row=reports.salesCostSummary(null,FROM,TO,1,50).rows().getFirst();
        amount(row,"manageFee","48");amount(row,"saleFee","10");amount(row,"taxFee","0");amount(row,"netProfit","337");amount(row,"costRatio","60");
        db.update("UPDATE finance_sales_cost_inputs SET tax_rate=.10,channel='FOREIGN'");
        row=reports.salesCostSummary(null,FROM,TO,1,50).rows().getFirst();amount(row,"saleFee","60");amount(row,"taxFee","100");amount(row,"netProfit","187");
        db.update("UPDATE finance_sales_cost_inputs SET freight_local=NULL");
        row=reports.salesCostSummary(null,FROM,TO,1,50).rows().getFirst();assertThat(row.get("freight")).isNull();assertThat(row.get("netProfit")).isNull();
        db.update("UPDATE finance_sales_cost_inputs SET freight_local=0");
        row=reports.salesCostSummary(null,FROM,TO,1,50).rows().getFirst();amount(row,"freight","0");amount(row,"netProfit","192");
    }
    @Test void returnAmountsStaySignedAndPendingCostNeverBecomesZeroProfit() {
        revenue("-100");cost("-60");input("OEM","0","-.5");
        var row=reports.salesCostSummary(null,FROM,TO,1,50).rows().getFirst();amount(row,"manageFee","-4.8");amount(row,"saleFee","-1");amount(row,"netProfit","-33.7");
        db.update("UPDATE v_stock_actual_cogs_postings SET pending=true");
        row=reports.salesCostSummary(null,FROM,TO,1,50).rows().getFirst();assertThat(row.get("saleCost")).isNull();assertThat(row.get("netProfit")).isNull();
        assertThatThrownBy(()->reports.salesCostSummary(null,FROM.plusDays(1),TO,1,50)).hasMessageContaining("完整");
    }
    static void revenue(String v){db.update("INSERT INTO ar_ap_ledger(id,client_id,direction,status,source_doc_type,bill_date,amount_original_local,currency_id,exchange_rate,is_deleted) VALUES(gen_random_uuid(),?,'AR',1,'SALES_SHIPMENT','2026-09-03',?,?,1,false)",CLIENT,new BigDecimal(v),CURRENCY);}
    static void cost(String v){db.update("INSERT INTO v_stock_actual_cogs_postings(client_id,business_date,amount_local,pending) VALUES(?,'2026-09-03',?,false)",CLIENT,new BigDecimal(v));}
    static void input(String channel,String tax,String freight){db.update("INSERT INTO finance_sales_cost_inputs(period,client_id,channel,tax_rate,freight_local,confirmed,client_name_snapshot,seller_name_snapshot,region_snapshot,director_snapshot) VALUES('2026-09',?,?,?,?,true,'匿名客户','','','')",CLIENT,channel,new BigDecimal(tax),new BigDecimal(freight));}
    static void amount(Map<String,Object> row,String field,String expected){assertThat((BigDecimal)row.get(field)).as(field).isEqualByComparingTo(expected);}
    static Query query(String sql){Query q=mock(Query.class);Map<String,Object> p=new LinkedHashMap<>();when(q.setParameter(anyString(),any())).thenAnswer(c->{p.put(c.getArgument(0),c.getArgument(1));return q;});when(q.getSingleResult()).thenAnswer(c->named.queryForObject(sql,p,Long.class));when(q.getResultList()).thenAnswer(c->named.query(sql,p,(r,n)->{Object[] row=new Object[r.getMetaData().getColumnCount()];for(int i=0;i<row.length;i++){row[i]=r.getObject(i+1);}return row;}));return q;}
}
