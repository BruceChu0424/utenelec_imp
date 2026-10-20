package com.uten.imp.features.sales.report;

import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.production.report.ProductionReportService;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.order.SalesPriceMasker;
import com.uten.imp.features.stock.StockCostMasker;
import com.uten.imp.features.stock.StockQueryService;
import com.uten.imp.features.stock.report.StockReportService;
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

/** Executes the generated detail, summary, facets and totals SQL against real catalog shapes. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class SalesReportUnitsPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    private static final UUID CLIENT=UUID.randomUUID(),GOODS=UUID.randomUUID(),COLOR=UUID.randomUUID(),
            EACH=UUID.randomUUID(),BOX=UUID.randomUUID(),USD=UUID.randomUUID(),OWNER=UUID.randomUUID();
    private static final LocalDate DATE=LocalDate.of(2026,10,12);
    private static JdbcTemplate db;
    private static NamedParameterJdbcTemplate named;
    private static SalesReportService sales;
    private static ProductionReportService production;
    private static StockReportService stock;
    private static SalesPriceMasker prices;
    private static List<String> dataColumns=List.of();

    @BeforeAll static void start(){
        PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(source);named=new NamedParameterJdbcTemplate(source);
        MigratedProjectionSchema.createCurrentTables(db,"sales_orders","sales_order_items","sales_shipments","sales_shipment_items",
                "sales_returns","sales_return_items","sales_other_shipments","sales_other_shipment_items",
                "clients","client_categories","client_director_v","employees","goods","colors","currencies","units",
                "warehouses","stock_balances","material_categories","production_plans","production_plan_items","subplan_links",
                "stock_documents","stock_document_items","departments");
        EntityManager em=mock(EntityManager.class);when(em.createNativeQuery(anyString())).thenAnswer(call->query(call.getArgument(0)));
        var policy=mock(SalesDocumentAccessPolicy.class);when(policy.nativeReadScope(anyString(),anyString()))
                .thenReturn(new SalesDocumentAccessPolicy.NativeReadScope("o.owner_employee_id IN (:salesOwners)","salesOwners",Set.of(OWNER)));
        prices=mock(SalesPriceMasker.class);sales=new SalesReportService(em,mock(SystemSettingsService.class),prices,policy);
        production=new ProductionReportService(em,mock(SystemSettingsService.class));
        stock=new StockReportService(em,mock(SystemSettingsService.class),mock(StockQueryService.class),mock(StockCostMasker.class));
        db.update("INSERT INTO clients(id,name) VALUES (?,'客户名')",CLIENT);
        db.update("INSERT INTO units(id,name) VALUES (?,'个'),(?,'箱')",EACH,BOX);
        db.update("INSERT INTO currencies(id,name,code) VALUES (?,'美金','002')",USD);
        db.update("INSERT INTO colors(id,name) VALUES (?,'颜色名')",COLOR);
        db.update("INSERT INTO goods(id,code,name,model,spec,unit_id) VALUES (?,'主档编号','主档货品','型号名','规格名',?)",GOODS,EACH);
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void reset(){
        db.execute("TRUNCATE sales_orders,sales_order_items,sales_shipments,sales_shipment_items,sales_returns,sales_return_items,sales_other_shipments,sales_other_shipment_items,production_plans,production_plan_items,stock_documents,stock_document_items");
        when(prices.canView()).thenReturn(true);
        dataColumns=List.of();
    }
    private static Query query(String sql){
        Query query=mock(Query.class);Map<String,Object> parameters=new LinkedHashMap<>();
        when(query.setParameter(anyString(),any())).thenAnswer(call->{parameters.put(call.getArgument(0),call.getArgument(1));return query;});
        when(query.getResultList()).thenAnswer(call->named.query(sql,parameters,(rs,index)->{
            Object[] row=new Object[rs.getMetaData().getColumnCount()];var aliases=new java.util.ArrayList<String>();
            for(int i=0;i<row.length;i++){row[i]=rs.getObject(i+1);aliases.add(rs.getMetaData().getColumnLabel(i+1));}
            if(sql.contains("LIMIT :__limit OFFSET :__offset")){ dataColumns=List.copyOf(aliases); }return row;
        }));
        when(query.getSingleResult()).thenAnswer(call->named.queryForObject(sql,parameters,Long.class));return query;
    }
    private record Doc(UUID id,String head,String items,String foreignKey,String bill){}
    private static Doc create(String type,UUID unit){
        String head=switch(type){case "ORDER"->"sales_orders";case "SHIPMENT"->"sales_shipments";case "RETURN"->"sales_returns";default->"sales_other_shipments";};
        String items=switch(type){case "ORDER"->"sales_order_items";case "SHIPMENT"->"sales_shipment_items";case "RETURN"->"sales_return_items";default->"sales_other_shipment_items";};
        String foreign=switch(type){case "ORDER"->"order_id";case "RETURN"->"return_id";default->"shipment_id";};
        UUID id=UUID.randomUUID();String bill="REPORT-"+type+"-"+id.toString().substring(0,8);
        db.update("INSERT INTO "+head+"(id,bill_no,bill_date,status,client_id,currency_id,owner_employee_id,total_original,total_local) VALUES (?,?,?,1,?,?,?,25,175)",id,bill,DATE,CLIENT,USD,OWNER);
        db.update("INSERT INTO "+items+"(id,"+foreign+",bill_no,bill_date,line_no,goods_id,goods_code_snapshot,goods_name_snapshot,color_id,unit_id,qty,price,amount_original,amount_local,discount) VALUES (gen_random_uuid(),?,?,?,1,?,'快照编号','快照货品',?,?,3,7,21,147,1)",id,bill,DATE,GOODS,COLOR,unit);
        return new Doc(id,head,items,foreign,bill);
    }
    private static ReportTableResponse detail(String type,String bill){return sales.detail(type,bill,CLIENT,null,(Short)null,null,null,null,Map.of(),1,50,null,null);}
    private static ReportTableResponse summary(String type){return sales.summary(type,null,CLIENT,null,(Short)null,null,null,null,Map.of(),1,50,null,null);}
    private static BigDecimal decimal(Map<String,Object> row,String key){return (BigDecimal)row.get(key);}
    private static void billOrder(Doc doc){
        UUID item=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,doc.id());
        db.update("INSERT INTO sales_shipments(id,bill_no,bill_date,status,finance_audit,shipment_kind,warehouse_work_status,currency_id) VALUES (gen_random_uuid(),'BILLED',?,1,1,'STANDARD','SHIPPED',?)",DATE,USD);
        db.update("INSERT INTO sales_shipment_items(id,shipment_id,order_item_id,amount_local) SELECT gen_random_uuid(),id,?,130.48 FROM sales_shipments WHERE bill_no='BILLED'",item);
    }

    @ParameterizedTest @ValueSource(strings={"ORDER","SHIPMENT","RETURN","OTHER_SHIPMENT"})
    void completeDetailsKeepPositionalFieldsAndRealCurrencyUnits(String type){
        Doc doc=create(type,BOX);
        if(type.equals("ORDER"))billOrder(doc);
        var result=detail(type,doc.bill());assertThat(result.rows()).hasSize(1);var row=result.rows().getFirst();
        assertThat(dataColumns.stream().filter(key->!key.startsWith("__")).toList()).isEqualTo(result.columns().stream().map(ReportColumn::key).toList());
        assertThat(row.get("goodsName")).isEqualTo("快照货品");assertThat(row.get("goodsCode")).isEqualTo("快照编号");
        assertThat(row.get("colorName")).isEqualTo("颜色名");assertThat(row.get("approved")).isEqualTo(true);
        assertThat(row.get("__unitName")).isEqualTo("箱");
        assertThat(decimal(row,"price")).isEqualByComparingTo("7");
        var price=result.columns().stream().filter(column->column.key().equals("price")).findFirst().orElseThrow();
        assertThat(price.unitLabel()).isNull();assertThat(row.get(price.unitKey())).isEqualTo("美金");
        assertThat(new BigDecimal((String)row.get("priceExact"))).isEqualByComparingTo("7");
        if(type.equals("ORDER")){
            assertThat(row.get("closed")).isEqualTo(false);assertThat(decimal(row,"billedLocalAmount")).isEqualByComparingTo("130.48");
            assertThat(decimal(row,"billedLocalTotal")).isEqualByComparingTo("130.48");assertThat(decimal(row,"amount")).isEqualByComparingTo("21");
        }else assertThat(decimal(row,"amount")).isEqualByComparingTo("147");
        assertThat(result.columns()).noneMatch(column->column.key().startsWith("__"));
    }
    @ParameterizedTest @ValueSource(strings={"ORDER","SHIPMENT","RETURN","OTHER_SHIPMENT"})
    void customerSummariesDoNotAddDifferentUnitsButKeepMoneyAndDocumentCounts(String type){
        create(type,EACH);var result=summary(type);var single=result.rows().getFirst();assertThat(decimal(single,"totalQty")).isEqualByComparingTo("3");
        assertThat(dataColumns.stream().filter(key->!key.startsWith("__")).toList()).isEqualTo(result.columns().stream().map(ReportColumn::key).toList());
        assertThat(single.get("__unitName")).isEqualTo("个");
        create(type,BOX);var mixed=summary(type);assertThat(mixed.rows()).hasSize(1);var row=mixed.rows().getFirst();
        assertThat(row.get("totalQty")).isNull();assertThat(row.get("__unitName")).isNull();
        assertThat(((Number)row.get("docCount")).longValue()).isEqualTo(2);
        assertThat(decimal(row,"totalAmount")).isEqualByComparingTo(type.equals("ORDER")?"42":"294");
    }
    @Test void ownerFilterAndMaskApplyToRowsExactTextsAndTotals(){
        Doc doc=create("ORDER",EACH);billOrder(doc);UUID hidden=UUID.randomUUID();
        db.update("INSERT INTO sales_orders(id,bill_no,bill_date,status,client_id,currency_id,owner_employee_id) VALUES (?,'HIDDEN',?,1,?,?,?)",hidden,DATE,CLIENT,USD,UUID.randomUUID());
        db.update("INSERT INTO sales_order_items(id,order_id,bill_no,bill_date,amount_original,unit_id,qty) VALUES (gen_random_uuid(),?,'HIDDEN',?,9999,?,9999)",hidden,DATE,EACH);
        when(prices.canView()).thenReturn(false);var result=detail("ORDER",null);
        assertThat(result.total()).isEqualTo(1);assertThat(result.rows()).hasSize(1);
        var row=result.rows().getFirst();assertThat(row.get("__srcId")).isEqualTo(doc.id().toString());
        assertThat(row.get("closed")).isEqualTo(false);assertThat(row).doesNotContainKey("closedExact");
        for(String key:List.of("price","amount","billedLocalAmount","billedLocalTotal","totalAmount")){
            assertThat(row.get(key)).isNull();assertThat(row.get(key+"Exact")).isNull();
        }
        assertThat(result.totals()).noneMatch(total->total.type().equals("money"));
    }
    @Test void legacyMissingOriginalAmountsAndCurrencyNamesStayUnknown(){
        Doc doc=create("ORDER",EACH);UUID unknown=UUID.randomUUID();
        db.update("INSERT INTO currencies(id,name,code) VALUES (?,NULL,'003')",unknown);
        db.update("UPDATE sales_orders SET currency_id=?,total_original=NULL WHERE id=?",unknown,doc.id());
        db.update("UPDATE sales_order_items SET amount_original=NULL WHERE order_id=?",doc.id());
        var result=summary("ORDER");var row=result.rows().getFirst();
        assertThat(row.get("currencyCode")).isNull();assertThat(row.get("totalAmount")).isNull();
        assertThat(result.totals()).filteredOn(total->total.key().equals("totalAmount")).singleElement()
                .satisfies(total->assertThat(total.groups()).containsExactly(new com.uten.imp.common.report.ReportTotalGroup(null,null,unknown.toString())));
    }
    @Test void differentUnitsInsideOneDocumentCannotBecomeAFalseCustomerTotal(){
        Doc doc=create("ORDER",EACH);
        db.update("INSERT INTO sales_order_items(id,order_id,bill_no,bill_date,unit_id,qty,amount_original) VALUES (gen_random_uuid(),?,?,?,?,2,14)",doc.id(),doc.bill(),DATE,BOX);
        var row=summary("ORDER").rows().getFirst();assertThat(row.get("totalQty")).isNull();assertThat(row.get("__unitName")).isNull();
        assertThat(decimal(row,"totalAmount")).isEqualByComparingTo("35");
    }
    @Test void sameUnitNamesDoNotProveTheSameUnitIdentity(){
        create("ORDER",EACH);UUID another=UUID.randomUUID();db.update("INSERT INTO units(id,name) VALUES (?,'个')",another);
        create("ORDER",another);var row=summary("ORDER").rows().getFirst();
        assertThat(row.get("totalQty")).isNull();assertThat(row.get("__unitName")).isNull();
    }
    @Test void distinctUnknownCurrencyIdsKeepIndividualMoneyButOnlyAPendingTotal(){
        for(String code:List.of("004","005")){
            Doc doc=create("ORDER",EACH);UUID currency=UUID.randomUUID();
            db.update("INSERT INTO currencies(id,name,code) VALUES (?,NULL,?)",currency,code);
            db.update("UPDATE sales_orders SET currency_id=? WHERE id=?",currency,doc.id());
        }
        var result=detail("ORDER",null);assertThat(result.rows()).hasSize(2);
        result.rows().forEach(row->{assertThat(row.get("currencyCode")).isNull();assertThat(decimal(row,"amount")).isEqualByComparingTo("21");});
        var total=result.totals().stream().filter(t->t.key().equals("amount")).findFirst().orElseThrow();
        assertThat(total.groups()).hasSize(2).allMatch(group->group.unit()==null&&group.value()==null&&group.identity()!=null);
    }
    @Test void distinctUnresolvedLineUnitsNeverBecomeOneNumericStockTotal(){
        UUID doc=UUID.randomUUID();db.update("INSERT INTO stock_documents(id,bill_no,bill_date,status,doc_type) VALUES (?,'REPORT-UNKNOWN-UNIT',?,1,'DRAW')",doc,DATE);
        for(int qty:List.of(2,3))db.update("INSERT INTO stock_document_items(id,doc_id,bill_type,goods_id,unit_id,unit_rate,qty,base_qty,issued_qty) VALUES (gen_random_uuid(),?,'DRAW',?,?,12,?,?,?)",doc,GOODS,UUID.randomUUID(),qty,qty*12,qty);
        var result=stock.detail("DRAW","REPORT-UNKNOWN-UNIT",null,null,(Short)null,null,null,null,null,Map.of(),1,50,null,null);
        assertThat(result.rows()).hasSize(2);assertThat(result.rows()).allMatch(row->row.get("unitName")==null);
        var total=result.totals().stream().filter(t->t.key().equals("drawQty")).findFirst().orElseThrow();
        assertThat(total.groups()).hasSize(2).allMatch(group->group.unit()==null&&group.value()==null&&group.identity()!=null);
        assertThat(result.rows().stream().map(row->decimal(row,"drawQty"))).containsExactlyInAnyOrder(new BigDecimal("2.0000"),new BigDecimal("3.0000"));
    }
    @Test void normalizedCurrencyNamesNeverMergeDifferentCurrencyIdentities(){
        create("ORDER",EACH);Doc other=create("ORDER",EACH);UUID currency=UUID.randomUUID();
        db.update("INSERT INTO currencies(id,name,code) VALUES (?,'US Dollar','USD')",currency);
        db.update("UPDATE sales_orders SET currency_id=? WHERE id=?",currency,other.id());
        var result=summary("ORDER");assertThat(result.rows()).hasSize(2);
        assertThat(result.rows()).allMatch(row->"美金".equals(row.get("currencyCode")));
        var groups=result.totals().stream().filter(t->t.key().equals("totalAmount")).findFirst().orElseThrow().groups();
        assertThat(groups).hasSize(2);assertThat(groups).allMatch(g->"美金".equals(g.unit())&&g.value().compareTo(new BigDecimal("21"))==0);
        assertThat(groups.toString()).contains(USD.toString(),currency.toString());
    }
    @Test void equalUnitNamesNeverMergeDifferentUnitIdentitiesInDetailTotals(){
        UUID unit=UUID.randomUUID(),doc=UUID.randomUUID();db.update("INSERT INTO units(id,name) VALUES (?,'个')",unit);
        db.update("INSERT INTO stock_documents(id,bill_no,bill_date,status,doc_type) VALUES (?,'REPORT-EQUAL-UNIT',?,1,'DRAW')",doc,DATE);
        db.update("INSERT INTO stock_document_items(id,doc_id,bill_type,goods_id,unit_id,unit_rate,qty,base_qty,issued_qty) VALUES (gen_random_uuid(),?,'DRAW',?,?,1,2,2,2),(gen_random_uuid(),?,'DRAW',?,?,1,3,3,3)",doc,GOODS,EACH,doc,GOODS,unit);
        var result=stock.detail("DRAW","REPORT-EQUAL-UNIT",null,null,(Short)null,null,null,null,null,Map.of(),1,50,null,null);
        var groups=result.totals().stream().filter(t->t.key().equals("drawQty")).findFirst().orElseThrow().groups();
        assertThat(groups).hasSize(2);assertThat(groups.stream().map(g->g.value())).containsExactlyInAnyOrder(new BigDecimal("2.0000"),new BigDecimal("3.0000"));
        assertThat(groups.toString()).contains(EACH.toString(),unit.toString());
    }
    @Test void productionProjectionUsesEachDeclaredFieldAndItsPlanUnit(){
        UUID plan=UUID.randomUUID();db.update("INSERT INTO production_plans(id,bill_no,bill_date,status) VALUES (?,'REPORT-PLAN',?,1)",plan,DATE);
        db.update("INSERT INTO production_plan_items(id,plan_id,bill_no,bill_date,goods_id,color_id,unit_id,qty,oqty,iqty) VALUES (gen_random_uuid(),?,'REPORT-PLAN',?,?,?,?,3,5,1)",plan,DATE,GOODS,COLOR,BOX);
        var result=production.planDetail("REPORT-PLAN",null,(Short)null,null,null,null,Map.of(),1,50,null,null);var row=result.rows().getFirst();
        assertThat(dataColumns.stream().filter(key->!key.startsWith("__")).toList()).isEqualTo(result.columns().stream().map(com.uten.imp.features.production.report.ReportColumn::key).toList());
        assertThat(row.get("goodsName")).isEqualTo("主档货品");assertThat(row.get("goodsCode")).isEqualTo("主档编号");
        assertThat(row.get("colorName")).isEqualTo("颜色名");assertThat(row.get("model")).isEqualTo("型号名");
        assertThat(row.get("__unitName")).isEqualTo("箱");assertThat(decimal(row,"qty")).isEqualByComparingTo("3");
    }
    @Test void stockActualBaseQuantityDoesNotUseTheDocumentBoxUnit(){
        UUID doc=UUID.randomUUID();db.update("INSERT INTO stock_documents(id,bill_no,bill_date,status,doc_type) VALUES (?,'REPORT-DRAW',?,1,'DRAW')",doc,DATE);
        db.update("INSERT INTO stock_document_items(id,doc_id,bill_type,goods_id,unit_id,unit_rate,qty,base_qty,issued_qty) VALUES (gen_random_uuid(),?,'DRAW',?,?,12,2,24,2)",doc,GOODS,BOX);
        var result=stock.detail("DRAW","REPORT-DRAW",null,null,(Short)null,null,null,null,null,Map.of(),1,50,null,null);var row=result.rows().getFirst();
        assertThat(dataColumns.stream().filter(key->!key.startsWith("__")).toList()).isEqualTo(result.columns().stream().map(com.uten.imp.features.stock.report.ReportColumn::key).toList());
        assertThat(decimal(row,"actualQty")).isEqualByComparingTo("24");assertThat(row.get("unitName")).isEqualTo("箱");
        var actual=result.columns().stream().filter(column->column.key().equals("actualQty")).findFirst().orElseThrow();
        assertThat(actual.unitKey()).isEqualTo("__baseUnitName");assertThat(row.get(actual.unitKey())).isEqualTo("个");
    }
}
