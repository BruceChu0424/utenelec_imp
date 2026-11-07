package com.uten.imp.features.report;

import com.uten.imp.common.export.*;
import com.uten.imp.common.report.ReportReadPlan;
import com.uten.imp.features.production.report.ProductionReportService;
import com.uten.imp.features.subcontract.report.SubcontractReportService;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import java.util.regex.Pattern;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

/** Runs the owning service projections and row mapper, not an invented frontend-only identity. */
class ProductionSubcontractLineIdentityTest {
    private static final UUID HEADER=new UUID(1,1), FIRST=new UUID(2,1),SECOND=new UUID(2,2),GROUP=new UUID(3,1);

    @Test void productionPhysicalPlanItemsRemainDistinctInListAndExportWithoutVisibleChanges() {
        var source=new Source(Mode.PHYSICAL);
        var service=new ProductionReportService(source.em);
        try(var ignored=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)) {
            var result=service.planDetail(null,null,null,null,null,null,Map.of(),1,50,"goodsName","asc");
            assertPhysicalRows(result.columns().stream().map(column->column.key()).toList(),result.rows());
            assertTrue(source.sql.getFirst().contains("i.id AS \"__lineId\""));
            assertTrue(source.sql.getFirst().contains("i.line_no NULLS LAST, i.id"));
            assertSelected(service.export("plan/detail",Map.of(),null,null));
        }
    }

    @ParameterizedTest @ValueSource(strings={"ORDER","RECEIPT","RETURN","MATERIAL_ISSUE","MATERIAL_RETURN"})
    void subcontractPhysicalItemsKeepTheirIdentityThroughMaskingAndExport(String kind) {
        var source=new Source(Mode.PHYSICAL);
        var service=new SubcontractReportService(source.em);
        try(var ignored=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)) {
            var result=switch(kind) {
                case "ORDER"->service.orderDetail(null,null,null,null,null,null,Map.of(),1,50,"goodsName","asc");
                case "RECEIPT"->service.receiptDetail(null,null,null,null,null,null,null,Map.of(),1,50,"goodsName","asc");
                case "RETURN"->service.returnDetail(null,null,null,null,null,null,null,Map.of(),1,50,"goodsName","asc");
                case "MATERIAL_ISSUE"->service.materialIssueDetail(null,null,null,null,null,null,null,Map.of(),1,50,"goodsName","asc");
                default->service.materialReturnDetail(null,null,null,null,null,null,null,Map.of(),1,50,"goodsName","asc");
            };
            assertPhysicalRows(result.columns().stream().map(column->column.key()).toList(),result.rows());
            assertTrue(source.sql.getFirst().contains("i.id AS \"__lineId\""));
            assertTrue(source.sql.getFirst().contains("i.id LIMIT"),source.sql.getFirst());
            assertSelected(service.export(kind+"/detail",Map.of(),null,null));
        }
    }

    @Test void documentSummariesRetainTheirHeaderGrainWithoutPhysicalLineProjection() {
        var source=new Source(Mode.HEADER);
        var production=new ProductionReportService(source.em);
        var subcontract=new SubcontractReportService(source.em);
        try(var ignored=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)) {
            var plan=production.planSummary(null,null,null,null,null,Map.of(),1,50,null,null);
            assertEquals(1,plan.rows().size());assertEquals(HEADER.toString(),plan.rows().getFirst().get("__srcId"));
            for(String kind:List.of("RECEIPT","RETURN","MATERIAL_ISSUE","MATERIAL_RETURN")) {
                var result=switch(kind) {
                    case "RECEIPT"->subcontract.receiptSummary(null,null,null,null,null,null,null,Map.of(),1,50,null,null);
                    case "RETURN"->subcontract.returnSummary(null,null,null,null,null,null,null,Map.of(),1,50,null,null);
                    case "MATERIAL_ISSUE"->subcontract.materialIssueSummary(null,null,null,null,null,null,null,Map.of(),1,50,null,null);
                    default->subcontract.materialReturnSummary(null,null,null,null,null,null,null,Map.of(),1,50,null,null);
                };
                assertEquals(1,result.rows().size());assertEquals(HEADER.toString(),result.rows().getFirst().get("__srcId"));
            }
        }
        assertTrue(source.sql.stream().noneMatch(sql->sql.contains("__lineId")));
    }

    @Test void inOutAggregationPublishesOnlyItsExistingGroupIdentityWithoutChangingGrouping() {
        var source=new Source(Mode.GROUP);
        var service=new SubcontractReportService(source.em);
        try(var ignored=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)) {
            var result=service.inOutStatus(null,LocalDate.of(2026,10,1),LocalDate.of(2026,10,31),null,1,50);
            assertEquals(2,result.rows().size());
            assertEquals(List.of(FIRST.toString(),SECOND.toString()),result.rows().stream().map(row->row.get("__supplierId")).toList());
            assertTrue(result.columns().stream().noneMatch(column->Set.of("__supplierId","__goodsId","__colorId").contains(column.key())));
            String sql=source.sql.getFirst();
            assertTrue(sql.contains("GROUP BY supplier_id, goods_id, goods_code_snapshot, goods_name_snapshot, color_id"));
            assertFalse(sql.contains("__lineId"));
            var selected=new ExportRowSelection(projection(Map.of("__supplierId",SECOND.toString(),"__goodsId",GROUP.toString(),"__colorId",GROUP.toString())));
            var columns=result.columns().stream().map(column->new ExportColumn(column.key(),column.label(),column.type())).toList();
            var filtered=selected.select(columns,result.rows());selected.verifyComplete();
            assertEquals(1,filtered.size());assertEquals(SECOND.toString(),filtered.getFirst().get("__supplierId"));
        }
    }

    private static void assertPhysicalRows(List<String> visible,List<Map<String,Object>> rows) {
        assertFalse(visible.contains("__lineId"));assertEquals(2,rows.size());
        assertEquals(List.of(FIRST.toString(),SECOND.toString()),rows.stream().map(row->row.get("__lineId")).toList());
        assertTrue(rows.stream().allMatch(row->HEADER.toString().equals(row.get("__srcId"))));
        var one=new LinkedHashMap<>(rows.getFirst());var two=new LinkedHashMap<>(rows.getLast());
        one.remove("__lineId");two.remove("__lineId");assertEquals(one,two,"The two physical items deliberately have identical visible facts");
        assertEquals(BigDecimal.ONE,rows.getFirst().get("qty"));
    }
    private static void assertSelected(ExportPayload payload) {
        assertFalse(payload.columns().stream().anyMatch(column->column.key().equals("__lineId")));
        var selected=new ExportRowSelection(projection(Map.of("__lineId",SECOND.toString())));
        var rows=selected.select(payload.columns(),payload.rows());selected.verifyComplete();
        assertEquals(1,rows.size());assertEquals(SECOND.toString(),rows.getFirst().get("__lineId"));
        assertEquals(BigDecimal.ONE,rows.getFirst().get("qty"));
    }
    private static TableColumnProjection projection(Map<String,String> selector) {
        return new TableColumnProjection("report-identity",null,List.of(
                new TableColumnProjection.Column("goodsName","货品名称",180.0,"text",null)),List.of(selector));
    }
    private enum Mode { PHYSICAL, HEADER, GROUP }
    private static final class Source {
        final EntityManager em=mock(EntityManager.class);
        final List<String> sql=new ArrayList<>();
        Source(Mode mode) {
            when(em.createNativeQuery(anyString())).thenAnswer(call->{
                String statement=call.getArgument(0);sql.add(statement);
                var query=mock(Query.class,RETURNS_SELF);
                when(query.getResultList()).thenAnswer(ignored->{
                    var aliases=aliases(statement);
                    var first=values(aliases,FIRST,mode);
                    if(mode==Mode.HEADER)return Collections.singletonList(first);
                    return List.of(first,values(aliases,SECOND,mode));
                });
                return query;
            });
        }
    }
    private static List<String> aliases(String sql) {
        int select=sql.contains("WITH flow AS")?sql.indexOf("SELECT sup.name AS \"supplierName\""):0;
        String projected=sql.substring(select);
        var from=Pattern.compile("\\bFROM\\b",Pattern.CASE_INSENSITIVE).matcher(projected);
        assertTrue(from.find(),sql);projected=projected.substring(0,from.start());
        var matcher=Pattern.compile("\\bAS\\s+\"([^\"]+)\"",Pattern.CASE_INSENSITIVE).matcher(projected);
        var aliases=new ArrayList<String>();while(matcher.find())aliases.add(matcher.group(1));
        assertFalse(aliases.isEmpty(),sql);return aliases;
    }
    private static Object[] values(List<String> aliases,UUID identity,Mode mode) {
        Set<String> numeric=Set.of("oqty","qty","iqty","receivedQty","returnedQty","differenceQty","weight","girth","price","amount","totalAmount","returnedAmount","boxQty","sourceOrderDifferenceQty",
                "openingQty","orderQty","issueQty","returnQty","mReturnQty","wasteQty","receiptQty","closingQty");
        Object[] row=new Object[aliases.size()];
        for(int index=0;index<aliases.size();index++) {
            String key=aliases.get(index);
            row[index]=key.equals("__lineId")?identity:key.equals("__srcId")?HEADER:
                    key.equals("__supplierId")&&mode==Mode.GROUP?identity:
                    key.endsWith("Id")?GROUP:numeric.contains(key)?BigDecimal.ONE:
                    Set.of("approved","closed").contains(key)?Boolean.TRUE:
                    key.endsWith("Date")?LocalDate.of(2026,10,11):"IDENTICAL";
        }
        return row;
    }
}
