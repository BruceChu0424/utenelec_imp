package com.uten.imp.features.purchase.report;

import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.subcontract.report.SubcontractReportService;
import com.uten.imp.security.CommercialPriceVisibility;
import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.time.LocalDate;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.containers.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Real report SQL and numeric rows; structural projections follow the migrated catalog. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ProcurementReportUnitsPostgresTest {
    private static final PostgreSQLContainer<?> DB=new PostgreSQLContainer<>("postgres:16-alpine");
    private static Connection connection;
    private static JdbcTemplate db;
    private static NamedParameterJdbcTemplate named;
    private static PurchaseReportService purchase;
    private static SubcontractReportService subcontract;
    private static CommercialPriceVisibility visibility;
    private static List<String> dataColumns=List.of();
    private static final UUID GOODS=UUID.randomUUID(),UNIT=UUID.randomUUID(),USD=UUID.randomUUID(),CNY=UUID.randomUUID();
    private static final UUID ALIAS_COLOR=UUID.randomUUID(),ALIAS_SUPPLIER=UUID.randomUUID();
    private static final LocalDate DATE=LocalDate.of(2026,10,12);

    @BeforeAll static void start()throws Exception{
        DB.start();connection=DriverManager.getConnection(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword());
        var source=new SingleConnectionDataSource(connection,true);db=new JdbcTemplate(source);named=new NamedParameterJdbcTemplate(source);
        MigratedProjectionSchema.createCurrentTables(db,"purchase_requests","purchase_request_items","purchase_orders","purchase_order_items",
                "purchase_receipts","purchase_receipt_items","purchase_returns","purchase_return_items","subcontract_receipts","subcontract_receipt_items",
                "subcontract_returns","subcontract_return_items","subcontract_orders","subcontract_order_items","subcontract_material_issues",
                "subcontract_material_issue_items","subcontract_material_returns","subcontract_material_return_items","subcontract_wastes","subcontract_waste_items",
                "suppliers","warehouses","employees","departments","legacy_departments","goods","colors","units","currencies","material_categories","stock_balances");
        EntityManager em=mock(EntityManager.class);when(em.createNativeQuery(anyString())).thenAnswer(call->query(call.getArgument(0)));
        visibility=mock(CommercialPriceVisibility.class);when(visibility.canViewPurchaseReport()).thenReturn(true);when(visibility.canViewSubcontractReport()).thenReturn(true);
        purchase=new PurchaseReportService(em,mock(SystemSettingsService.class));subcontract=new SubcontractReportService(em,mock(SystemSettingsService.class));
        ReflectionTestUtils.setField(purchase,"commercialPriceVisibility",visibility);ReflectionTestUtils.setField(subcontract,"commercialPriceVisibility",visibility);
        db.update("INSERT INTO units(id,name) VALUES (?,'个')",UNIT);db.update("INSERT INTO currencies(id,code,name) VALUES (?,'USD','USD'),(?,'CNY','人民币')",USD,CNY);
        db.update("INSERT INTO goods(id,code,name,unit_id) VALUES (?,'REPORT-GOODS','测试货品',?)",GOODS,UNIT);
        db.update("INSERT INTO colors(id,name) VALUES (?,'对应颜色')",ALIAS_COLOR);
        db.update("INSERT INTO suppliers(id,name) VALUES (?,'对应供应商')",ALIAS_SUPPLIER);
    }
    @AfterAll static void stop()throws Exception{if(connection!=null){ connection.close(); }DB.stop();}
    @BeforeEach void reset(){
        db.execute("TRUNCATE purchase_requests,purchase_request_items,purchase_orders,purchase_order_items,purchase_receipts,purchase_receipt_items,purchase_returns,purchase_return_items,subcontract_receipts,subcontract_receipt_items,subcontract_returns,subcontract_return_items,subcontract_orders,subcontract_order_items,subcontract_material_issues,subcontract_material_issue_items,subcontract_material_returns,subcontract_material_return_items,subcontract_wastes,subcontract_waste_items");
        dataColumns=List.of();
    }
    private static Query query(String sql){
        Query q=mock(Query.class);Map<String,Object> values=new LinkedHashMap<>();
        when(q.setParameter(anyString(),any())).thenAnswer(call->{values.put(call.getArgument(0),call.getArgument(1));return q;});
        when(q.getResultList()).thenAnswer(call->named.query(sql,values,(rs,index)->{
            Object[] row=new Object[rs.getMetaData().getColumnCount()];var aliases=new java.util.ArrayList<String>();
            for(int i=0;i<row.length;i++){row[i]=rs.getObject(i+1);aliases.add(rs.getMetaData().getColumnLabel(i+1));}
            if(sql.contains("LIMIT :__limit OFFSET :__offset")){ dataColumns=List.copyOf(aliases); }return row;
        }));
        when(q.getSingleResult()).thenAnswer(call->named.queryForObject(sql,values,Long.class));return q;
    }

    @Test void subcontractInOutSearchRanksCompleteNamesAcrossPagesAndKeepsTheDeclaredProjectionAndMask() {
        searchReceipt("A-NEAR","Metric Screw extra");
        searchReceipt("Z-EXACT","Metric Screw");
        var first=subcontract.inOutStatus(ALIAS_SUPPLIER,DATE,DATE,"Metric Screw",1,1);
        assertThat(first.total()).isEqualTo(2);
        assertThat(first.totalPages()).isEqualTo(2);
        assertThat(first.rows()).hasSize(1);
        assertThat(first.rows().getFirst()).containsEntry("goodsCode","Z-EXACT")
                .containsEntry("goodsName","Metric Screw").containsEntry("colorName","对应颜色")
                .containsEntry("spec","SEARCH-SPEC").containsEntry("model","SEARCH-MODEL").containsEntry("series","SEARCH-SERIES");
        assertThat(subcontract.inOutStatus(ALIAS_SUPPLIER,DATE,DATE,"Metric Screw",2,1).rows().getFirst())
                .containsEntry("goodsCode","A-NEAR");
        assertThat(subcontract.inOutStatus(ALIAS_SUPPLIER,DATE,DATE,"对应供应商 Z-EXACT",1,20).rows())
                .extracting(row->row.get("goodsCode")).containsExactly("Z-EXACT");
        searchReceipt("A%_B","literal");
        searchReceipt("AxYB","near literal");
        assertThat(subcontract.inOutStatus(ALIAS_SUPPLIER,DATE,DATE,"A%_B",1,20).rows())
                .extracting(row->row.get("goodsCode")).containsExactly("A%_B");
        when(visibility.canViewSubcontractReport()).thenReturn(false);
        try {
            var masked=subcontract.inOutStatus(ALIAS_SUPPLIER,DATE,DATE,"A%_B",1,20);
            assertThat(masked.columns()).noneMatch(column->column.key().equals("price")||column.key().equals("amount"));
            assertThat(masked.rows().getFirst()).doesNotContainKeys("price","amount","priceExact","amountExact");
            assertThat(masked.rows().getFirst()).containsEntry("goodsCode","A%_B");
        } finally {
            when(visibility.canViewSubcontractReport()).thenReturn(true);
        }
    }

    private static void searchReceipt(String code,String name) {
        UUID doc=UUID.randomUUID(),goods=UUID.randomUUID();
        db.update("INSERT INTO goods(id,code,name,unit_id,spec,model,series) VALUES(?,?,?,?,'SEARCH-SPEC','SEARCH-MODEL','SEARCH-SERIES')",goods,code,name,UNIT);
        db.update("INSERT INTO subcontract_receipts(id,bill_no,bill_date,status,currency_id,supplier_id) VALUES(?,?,?,1,?,?)",doc,"SEARCH-"+doc,DATE,USD,ALIAS_SUPPLIER);
        db.update("""
                INSERT INTO subcontract_receipt_items(id,receipt_id,bill_no,bill_date,goods_id,goods_code_snapshot,goods_name_snapshot,
                    color_id,unit_id,qty,unit_rate,price,amount_local)
                VALUES(gen_random_uuid(),?,?,?,?,?,?,?, ?,1,1,10,70)
                """,doc,"SEARCH-"+doc,DATE,goods,code,name,ALIAS_COLOR,UNIT);
    }
    @Test void purchaseForeignAmountsAndLocalTotalKeepDifferentUnitsAndExactValues(){
        UUID doc=UUID.randomUUID();db.update("INSERT INTO purchase_orders(id,bill_no,bill_date,status,currency_id,total_local) VALUES (?,'REPORT-PURCHASE',?,1,?,140)",doc,DATE,USD);
        db.update("INSERT INTO purchase_order_items(id,order_id,bill_no,bill_date,goods_id,goods_code_snapshot,goods_name_snapshot,unit_id,qty,price,amount_original,amount_local,received_qty,returned_qty) VALUES (gen_random_uuid(),?,'REPORT-PURCHASE',?,?,'REPORT-GOODS','测试货品',?,2,10,20,140,0,0)",doc,DATE,GOODS,UNIT);
        var report=purchase.orderDetail("REPORT-PURCHASE",null,null,null,null,null,Map.of(),1,20,null,null);
        assertThat(report.rows()).hasSize(1);var row=report.rows().getFirst();
        assertThat(row.get("__currencyName")).isEqualTo("美金");assertThat(row.get("__unitName")).isEqualTo("个");
        assertThat((BigDecimal)row.get("price")).isEqualByComparingTo("10");assertThat((BigDecimal)row.get("amount")).isEqualByComparingTo("20");
        assertThat((BigDecimal)row.get("totalAmount")).isEqualByComparingTo("140");
        assertThat(new BigDecimal((String)row.get("priceExact"))).isEqualByComparingTo("10");
        assertThat(new BigDecimal((String)row.get("amountExact"))).isEqualByComparingTo("20");
        assertThat(report.columns().stream().filter(c->c.key().equals("price")).findFirst().orElseThrow().unitKey()).isEqualTo("__currencyName");
        assertThat(report.columns().stream().filter(c->c.key().equals("totalAmount")).findFirst().orElseThrow().unitLabel()).isEqualTo("元");
        assertThat(report.columns()).noneMatch(c->c.key().startsWith("__"));
    }
    @Test void anUnknownLegacyNumericCurrencyCodeIsNeverPresentedAsDollarsOrYuan(){
        UUID currency=UUID.randomUUID(),doc=UUID.randomUUID();
        db.update("INSERT INTO currencies(id,code,name) VALUES (?,'002',NULL)",currency);
        db.update("INSERT INTO purchase_orders(id,bill_no,bill_date,status,currency_id,total_local) VALUES (?,'REPORT-UNKNOWN',?,1,?,70)",doc,DATE,currency);
        db.update("INSERT INTO purchase_order_items(id,order_id,bill_no,bill_date,goods_id,unit_id,qty,price,amount_original,amount_local) VALUES (gen_random_uuid(),?,'REPORT-UNKNOWN',?,?,?,1,10,10,70)",doc,DATE,GOODS,UNIT);
        var report=purchase.orderDetail("REPORT-UNKNOWN",null,null,null,null,null,Map.of(),1,20,null,null);
        assertThat(report.rows().getFirst().get("__currencyName")).isNull();
        assertThat(report.columns().stream().filter(c->c.key().equals("price")).findFirst().orElseThrow().unitLabel()).isNull();
        assertThat(report.columns().stream().filter(c->c.key().equals("amount")).findFirst().orElseThrow().unitKey()).isEqualTo("__currencyName");
    }
    @Test void subcontractOriginalPriceLocalAmountAndBaseUnitOverviewDoNotMixCurrencies(){
        receipt("REPORT-SUBCONTRACT",USD,"2","3","10","140");
        var detail=subcontract.receiptDetail("REPORT-SUBCONTRACT",null,null,null,null,null,null,Map.of(),1,20,null,null);
        var row=detail.rows().getFirst();assertThat(row.get("__currencyName")).isEqualTo("美金");
        assertThat((BigDecimal)row.get("amount")).isEqualByComparingTo("140");
        assertThat(detail.columns().stream().filter(c->c.key().equals("amount")).findFirst().orElseThrow().unitLabel()).isEqualTo("元");
        var overview=subcontract.inOutStatus(null,DATE,DATE,null,1,20);var first=overview.rows().getFirst();
        assertThat((BigDecimal)first.get("receiptQty")).isEqualByComparingTo("6");assertThat(first.get("__unitName")).isEqualTo("个");
        assertThat(first.get("__currencyName")).isEqualTo("美金");
        receipt("REPORT-SUBCONTRACT-CNY",CNY,"1","1","70","70");
        var mixed=subcontract.inOutStatus(null,DATE,DATE,null,1,20).rows().getFirst();
        assertThat(mixed.get("price")).isNull();assertThat(mixed.get("__currencyName")).isNull();
        assertThat((BigDecimal)mixed.get("amount")).isEqualByComparingTo("210");
    }
    @ParameterizedTest @ValueSource(strings={"PURCHASE_REQUEST","PURCHASE_ORDER","PURCHASE_RECEIPT","PURCHASE_RETURN",
            "SUBCONTRACT_RECEIPT","SUBCONTRACT_RETURN","MATERIAL_ISSUE","MATERIAL_RETURN"})
    void everyProcurementDetailUsesTheExactDeclaredProjectionOrder(String type){
        String head=switch(type){case "PURCHASE_REQUEST"->"purchase_requests";case "PURCHASE_ORDER"->"purchase_orders";
            case "PURCHASE_RECEIPT"->"purchase_receipts";case "PURCHASE_RETURN"->"purchase_returns";
            case "SUBCONTRACT_RECEIPT"->"subcontract_receipts";case "SUBCONTRACT_RETURN"->"subcontract_returns";
            case "MATERIAL_ISSUE"->"subcontract_material_issues";default->"subcontract_material_returns";};
        String items=switch(type){case "PURCHASE_REQUEST"->"purchase_request_items";case "PURCHASE_ORDER"->"purchase_order_items";
            case "PURCHASE_RECEIPT"->"purchase_receipt_items";case "PURCHASE_RETURN"->"purchase_return_items";
            case "SUBCONTRACT_RECEIPT"->"subcontract_receipt_items";case "SUBCONTRACT_RETURN"->"subcontract_return_items";
            case "MATERIAL_ISSUE"->"subcontract_material_issue_items";default->"subcontract_material_return_items";};
        String parent=switch(type){case "PURCHASE_REQUEST"->"request_id";case "PURCHASE_ORDER"->"order_id";
            case "PURCHASE_RECEIPT","SUBCONTRACT_RECEIPT"->"receipt_id";case "PURCHASE_RETURN","SUBCONTRACT_RETURN"->"return_id";
            case "MATERIAL_ISSUE"->"issue_id";default->"material_return_id";};
        UUID doc=UUID.randomUUID(),goods=UUID.randomUUID();String bill="ALIAS-"+doc.toString().substring(0,8);
        db.update("INSERT INTO goods(id,code,name,unit_id,model,c_number,spec,material,default_supplier_id) VALUES (?,?, '主档名称',?,'对应型号','对应客户型号','对应规格','对应材质',?)",goods,"ALIAS-"+goods.toString().substring(0,8),UNIT,ALIAS_SUPPLIER);
        db.update("INSERT INTO "+head+"(id,bill_no,bill_date,status) VALUES (?,?,?,1)",doc,bill,DATE);
        db.update("INSERT INTO "+items+"(id,"+parent+",bill_no,bill_date,goods_id,goods_code_snapshot,goods_name_snapshot,color_id,unit_id,qty) VALUES (gen_random_uuid(),?,?,?,?,'对应编号','对应货品',?,?,2)",doc,bill,DATE,goods,ALIAS_COLOR,UNIT);
        Map<String,Object> row;List<String> declared;
        if(type.startsWith("PURCHASE_")){
            var report=switch(type){case "PURCHASE_REQUEST"->purchase.requestDetail(bill,null,null,null,null,Map.of(),1,20,null,null);
                case "PURCHASE_ORDER"->purchase.orderDetail(bill,null,null,null,null,null,Map.of(),1,20,null,null);
                case "PURCHASE_RECEIPT"->purchase.receiptDetail(bill,null,null,null,null,null,null,Map.of(),1,20,null,null);
                default->purchase.returnDetail(bill,null,null,null,null,null,null,Map.of(),1,20,null,null);};
            assertThat(report.rows()).hasSize(1);row=report.rows().getFirst();declared=report.columns().stream().map(ReportColumn::key).toList();
            if(type.equals("PURCHASE_REQUEST")){
                assertThat(report.columns()).filteredOn(c->c.key().equals("price")||c.key().equals("amount"))
                        .allMatch(c->"元".equals(c.unitLabel())&&c.unitKey()==null);
                assertThat(row).doesNotContainKey("__currencyName");
            }
        }else{
            var report=switch(type){case "SUBCONTRACT_RECEIPT"->subcontract.receiptDetail(bill,null,null,null,null,null,null,Map.of(),1,20,null,null);
                case "SUBCONTRACT_RETURN"->subcontract.returnDetail(bill,null,null,null,null,null,null,Map.of(),1,20,null,null);
                case "MATERIAL_ISSUE"->subcontract.materialIssueDetail(bill,null,null,null,null,null,null,Map.of(),1,20,null,null);
                default->subcontract.materialReturnDetail(bill,null,null,null,null,null,null,Map.of(),1,20,null,null);};
            assertThat(report.rows()).hasSize(1);row=report.rows().getFirst();declared=report.columns().stream().map(com.uten.imp.features.subcontract.report.ReportColumn::key).toList();
        }
        assertThat(dataColumns.stream().filter(key->!key.startsWith("__")).toList()).isEqualTo(declared);
        assertThat(row.get("goodsName")).isEqualTo("对应货品");assertThat(row.get("goodsCode")).isEqualTo("对应编号");
        assertThat(row.get("colorName")).isEqualTo("对应颜色");assertThat(row.get("model")).isEqualTo("对应型号");
        assertThat(row.get("customerModel")).isEqualTo("对应客户型号");assertThat(row.get("spec")).isEqualTo("对应规格");
    }
    private static void receipt(String bill,UUID currency,String qty,String rate,String price,String local){
        UUID doc=UUID.randomUUID();db.update("INSERT INTO subcontract_receipts(id,bill_no,bill_date,status,currency_id,total_local) VALUES (?,?,?,1,?,?)",doc,bill,DATE,currency,new BigDecimal(local));
        db.update("INSERT INTO subcontract_receipt_items(id,receipt_id,bill_no,bill_date,goods_id,goods_code_snapshot,goods_name_snapshot,unit_id,qty,unit_rate,price,amount_local) VALUES (gen_random_uuid(),?,?,? ,?,'REPORT-GOODS','测试货品',?,?,?,?,?)",doc,bill,DATE,GOODS,UNIT,new BigDecimal(qty),new BigDecimal(rate),new BigDecimal(price),new BigDecimal(local));
    }
}
