package com.uten.imp.common.report;

import com.uten.imp.common.export.*;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.order.SalesPriceMasker;
import com.uten.imp.features.sales.report.SalesReportService;
import com.uten.imp.features.purchase.report.PurchaseReportService;
import com.uten.imp.security.CommercialPriceVisibility;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.sql.Date;
import java.util.*;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Exercise each actual detail reader and its export adapter, not fabricated frontend-only row IDs. */
class CommercialReportLineIdentityTest {
    private static final UUID HEADER=UUID.fromString("10000000-0000-4000-8000-000000000001");
    private static final UUID FIRST=UUID.fromString("20000000-0000-4000-8000-000000000001");
    private static final UUID SECOND=UUID.fromString("20000000-0000-4000-8000-000000000002");

    @ParameterizedTest
    @CsvSource({
        "sales,ORDER/detail,sales_order_items", "sales,SHIPMENT/detail,sales_shipment_items",
        "sales,RETURN/detail,sales_return_items", "sales,OTHER_SHIPMENT/detail,sales_other_shipment_items",
        "purchase,expediting,purchase_order_items", "purchase,request/detail,purchase_request_items",
        "purchase,order/detail,purchase_order_items", "purchase,receipt/detail,purchase_receipt_items",
        "purchase,return/detail,purchase_return_items"
    })
    void equalVisibleLinesRetainTheirPhysicalIdentityInListAndExport(String domain,String report,String table) {
        var fixture=new Fixture();
        Rows listed;
        try(var ignored=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)) {
            listed=fixture.read(domain,report);
        }
        assertTrue(fixture.lastSql.contains("FROM "+table+" i"));
        assertTrue(fixture.lastSql.contains("i.id AS \"__lineId\""));
        assertTrue(fixture.lastSql.contains("i.id LIMIT :__limit"),"Visible sort ties retain the existing physical ID order");
        assertFalse(listed.columns.contains("__lineId"),"Identity must not become a displayed/exported column");
        assertEquals(2,listed.rows.size());
        assertEquals(HEADER.toString(),listed.rows.getFirst().get("__srcId"));
        assertEquals(HEADER.toString(),listed.rows.getLast().get("__srcId"));
        assertEquals(FIRST.toString(),listed.rows.getFirst().get("__lineId"));
        assertEquals(SECOND.toString(),listed.rows.getLast().get("__lineId"));
        for(String key:listed.columns) assertEquals(listed.rows.getFirst().get(key),listed.rows.getLast().get(key),key);
        String quantityKey=listed.columns.contains("qty")?"qty":"inboundQty";
        assertEquals(new BigDecimal("5.0001"),listed.rows.getFirst().get(quantityKey));

        ExportPayload exported=fixture.export(domain,report);
        assertEquals(2,exported.rows().size());
        assertFalse(exported.columns().stream().anyMatch(column->column.key().startsWith("__")));
        assertEquals(SECOND.toString(),exported.rows().getLast().get("__lineId"));
        var selection=new ExportRowSelection(new TableColumnProjection("commercial-lines",null,
                List.of(new TableColumnProjection.Column("goodsName","货品名称",180.0,"text",null)),
                List.of(Map.of("__lineId",SECOND.toString()))));
        var selected=selection.select(exported.columns(),exported.rows());
        selection.verifyComplete();
        assertEquals(1,selected.size());
        assertEquals(SECOND.toString(),selected.getFirst().get("__lineId"));
        assertEquals(new BigDecimal("5.0001"),selected.getFirst().get(quantityKey));
    }

    @ParameterizedTest
    @CsvSource({"sales,ORDER/summary","sales,SHIPMENT/summary","sales,RETURN/summary","sales,OTHER_SHIPMENT/summary",
            "purchase,request/summary","purchase,order/summary","purchase,receipt/summary","purchase,return/summary"})
    void summaryGrainIsNotSplitByAHiddenPhysicalLine(String domain,String report) {
        var fixture=new Fixture();fixture.produceRows=false;
        try(var ignored=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)) { fixture.read(domain,report); }
        assertFalse(fixture.lastSql.contains("__lineId"));
    }

    private record Rows(List<String> columns,List<Map<String,Object>> rows) { }
    private static final class Fixture {
        final EntityManager em=mock(EntityManager.class);
        final SystemSettingsService settings=mock(SystemSettingsService.class);
        final SalesReportService sales;
        final PurchaseReportService purchase;
        String lastSql;
        boolean produceRows=true;
        Fixture() {
            when(settings.readInt(any())).thenReturn(50_000);
            var access=mock(SalesDocumentAccessPolicy.class);
            when(access.nativeReadScope(anyString(),anyString())).thenReturn(
                    new SalesDocumentAccessPolicy.NativeReadScope("1=1",null,Set.of()));
            var prices=mock(SalesPriceMasker.class);when(prices.canView()).thenReturn(true);
            sales=new SalesReportService(em,settings,prices,access);
            purchase=new PurchaseReportService(em,settings);
            var commercial=mock(CommercialPriceVisibility.class);when(commercial.canViewPurchaseReport()).thenReturn(true);
            ReflectionTestUtils.setField(purchase,"commercialPriceVisibility",commercial);
            when(em.createNativeQuery(anyString())).thenAnswer(call->{
                lastSql=call.getArgument(0);
                var query=mock(Query.class);
                when(query.setParameter(anyString(),any())).thenReturn(query);
                when(query.getResultList()).thenAnswer(ignored->produceRows?physicalRows(lastSql):List.of());
                return query;
            });
        }
        Rows read(String domain,String report) {
            if(domain.equals("sales")) {
                var pieces=report.split("/");
                var response=pieces[1].equals("detail")
                        ?sales.detail(pieces[0],null,null,null,null,null,null,null,Map.of(),1,50,"goodsName","desc")
                        :sales.summary(pieces[0],null,null,null,null,null,null,null,Map.of(),1,50,null,null);
                return new Rows(response.columns().stream().map(column->column.key()).toList(),response.rows());
            }
            var response=switch(report) {
                case "expediting"->purchase.expediting(null,null,null,null,null,Map.of(),1,50,"goodsName","desc");
                case "request/detail"->purchase.requestDetail(null,null,null,null,null,Map.of(),1,50,"goodsName","desc");
                case "order/detail"->purchase.orderDetail(null,null,null,null,null,null,Map.of(),1,50,"goodsName","desc");
                case "receipt/detail"->purchase.receiptDetail(null,null,null,null,null,null,null,Map.of(),1,50,"goodsName","desc");
                case "return/detail"->purchase.returnDetail(null,null,null,null,null,null,null,Map.of(),1,50,"goodsName","desc");
                case "request/summary"->purchase.requestSummary(null,null,null,null,null,Map.of(),1,50,null,null);
                case "order/summary"->purchase.orderSummary(null,null,null,null,null,null,Map.of(),1,50,null,null);
                case "receipt/summary"->purchase.receiptSummary(null,null,null,null,null,null,null,Map.of(),1,50,null,null);
                case "return/summary"->purchase.returnSummary(null,null,null,null,null,null,null,Map.of(),1,50,null,null);
                default->throw new AssertionError(report);
            };
            return new Rows(response.columns().stream().map(column->column.key()).toList(),response.rows());
        }
        ExportPayload export(String domain,String report) {
            return domain.equals("sales")?sales.export(report,Map.of(),"goodsName","desc")
                    :purchase.export(report,Map.of(),"goodsName","desc");
        }
        private static List<Object[]> physicalRows(String sql) {
            int from=Pattern.compile("\\bFROM\\b",Pattern.CASE_INSENSITIVE).matcher(sql).results().findFirst().orElseThrow().start();
            var matcher=Pattern.compile("\\bAS\\s+\"([^\"]+)\"",Pattern.CASE_INSENSITIVE).matcher(sql.substring(0,from));
            var keys=new ArrayList<String>();while(matcher.find())keys.add(matcher.group(1));
            var result=new ArrayList<Object[]>();
            for(UUID line:List.of(FIRST,SECOND)) {
                var row=new Object[keys.size()];
                for(int index=0;index<keys.size();index++) row[index]=switch(keys.get(index)) {
                    case "__lineId"->line;case "__srcId"->HEADER;
                    case "goodsName"->"完全相同货品";case "goodsCode"->"SAME-001";case "billNo"->"SHARED-001";
                    case "billDate"->Date.valueOf("2026-10-01");case "qty","inboundQty"->new BigDecimal("5.0001");default->null;
                };
                result.add(row);
            }
            return result;
        }
    }
}
