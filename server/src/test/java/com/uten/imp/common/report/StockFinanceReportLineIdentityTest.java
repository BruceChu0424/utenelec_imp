package com.uten.imp.common.report;

import com.uten.imp.common.export.*;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.asset.FixedAssetService;
import com.uten.imp.features.finance.cost.FinanceCostService;
import com.uten.imp.features.finance.gl.GlReportService;
import com.uten.imp.features.finance.report.FinanceReportService;
import com.uten.imp.features.finance.report.PartyMonthlySummaryService;
import com.uten.imp.features.finance.statement.FinanceStatementService;
import com.uten.imp.features.stock.StockCostMasker;
import com.uten.imp.features.stock.StockQueryService;
import com.uten.imp.features.stock.report.StockReportService;
import com.uten.imp.security.DocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.ValueSource;
import java.math.BigDecimal;
import java.sql.Date;
import java.util.*;
import java.util.regex.Pattern;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Actual owning SQL and row mappers supply identities; equal visible facts never establish equivalence. */
class StockFinanceReportLineIdentityTest {
    static final UUID HEADER=UUID.fromString("10000000-0000-4000-8000-000000000001");
    static final UUID FIRST=UUID.fromString("20000000-0000-4000-8000-000000000001");
    static final UUID SECOND=UUID.fromString("20000000-0000-4000-8000-000000000002");

    @ParameterizedTest @CsvSource({"TRANSFER,qty","OTHER_IN,qty","DRAW,drawQty","WDRAW,returnQty",
            "FINISHED_IN,qty","FINISHED_OUT,qty","CHECK,actualQty"})
    void stockDetailUsesItsPhysicalItemIdInTheActualListAndExport(String kind,String quantity) {
        var fixture=new Fixture(true);
        try(var ignored=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)) {
            var result=fixture.stock.detail(kind,null,null,null,null,null,null,null,null,Map.of(),1,50,"goodsName","desc");
            assertRows(result.columns().stream().map(column->column.key()).toList(),result.rows(),quantity,SECOND.toString());
            assertTrue(fixture.dataSql.contains("i.id AS \"__lineId\""));
            assertTrue(fixture.dataSql.contains("FROM stock_document_items i"));
        }
        assertExport(fixture.stock.export(kind+"/detail",Map.of(),"goodsName","desc"),quantity,SECOND.toString());
    }

    @ParameterizedTest @CsvSource({
            "ar-ap/detail,l.id,ar_ap_ledger,amountOriginal",
            "ar-ap/order-plan,sales_order.id,sales_orders,orderOriginal",
            "receipt/detail,COALESCE(i.id;t.id),finance_receipt_lines,amountOriginal",
            "expense/detail,i.id,finance_expense_items,lineAmount",
            "expense/summary,i.id,finance_expense_items,lineAmount",
            "income/detail,i.id,finance_other_income_items,incomeAmount",
            "income/summary,i.id,finance_other_income_items,incomeAmount",
            "fee-offset/detail,COALESCE(i.id;t.id),finance_receipt_lines,writeOffOriginal",
            "bank/detail,i.id,finance_bank_transfer_lines,amount"
    })
    void financeKeepsTheExistingPhysicalGrainEvenWhenItsPageIsNamedSummary(String report,String expression,String table,String money) {
        var fixture=new Fixture(true);
        try(var ignored=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)) {
            var result=fixture.financeRows(report);
            assertRows(result.columns,result.rows,money,SECOND.toString());
            assertTrue(fixture.dataSql.contains(expression.replace(';',',')+" AS \"__lineId\"")
                    ||report.equals("bank/detail")&&fixture.dataSql.contains(",i.id,"),fixture.dataSql);
            assertTrue(fixture.dataSql.contains(table));
        }
        assertExport(fixture.finance.export(report,report.equals("ar-ap/detail")?Map.of("direction","AR"):Map.of(),null,null),money,SECOND.toString());
    }

    @ParameterizedTest @ValueSource(strings={"party/flow","party/detail"})
    void partyStreamsRetainActualEventIdAndEventVariantWithoutChangingBalanceWindows(String report) {
        var fixture=new Fixture(true);
        try(var ignored=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)) {
            var result=fixture.financeRows(report);
            assertRows(result.columns,result.rows,"salesOriginal","10:"+SECOND);
            assertTrue(fixture.dataSql.contains("(\"eventOrder\"::text||':'||\"eventId\"::text) AS \"__lineId\""));
            assertTrue(fixture.dataSql.contains("event_id AS \"eventId\""));
            assertTrue(fixture.dataSql.contains("ROWS UNBOUNDED PRECEDING"));
        }
    }

    @Test void headerSummariesStayAtTheirExistingHeaderGrain() {
        var fixture=new Fixture(false);
        try(var ignored=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)) {
            for(String kind:List.of("TRANSFER","OTHER_IN","DRAW","WDRAW","FINISHED_IN","FINISHED_OUT","CHECK")) {
                var result=fixture.stock.summary(kind,null,null,null,null,null,null,null,null,Map.of(),1,50,null,null);
                assertEquals(1,result.rows().size());
                assertFalse(result.rows().getFirst().containsKey("__lineId"));
                assertEquals(HEADER.toString(),result.rows().getFirst().get("__srcId"));
            }
            var bank=fixture.finance.bankReport("summary",null,null,null,null,null,Map.of(),1,50,null,null);
            assertEquals(1,bank.rows().size());assertFalse(bank.rows().getFirst().containsKey("__lineId"));
            assertEquals(HEADER.toString(),bank.rows().getFirst().get("__srcId"));
        }
    }

    private static void assertRows(List<String> visible,List<Map<String,Object>> rows,String numeric,String selectedId) {
        assertFalse(visible.contains("__lineId"));assertEquals(2,rows.size());
        assertNotNull(rows.getFirst().get("__lineId"));assertEquals(selectedId,rows.getLast().get("__lineId"));
        var first=new LinkedHashMap<>(rows.getFirst());var second=new LinkedHashMap<>(rows.getLast());
        first.remove("__lineId");second.remove("__lineId");
        assertEquals(first,second,"All former facts are deliberately identical, including their header");
        assertEquals(new BigDecimal("5.0001"),rows.getFirst().get(numeric));
    }
    private static void assertExport(ExportPayload payload,String numeric,String selectedId) {
        assertEquals(2,payload.rows().size());assertTrue(payload.columns().stream().noneMatch(column->column.key().startsWith("__")));
        var selection=new ExportRowSelection(new TableColumnProjection("physical-lines",null,
                List.of(new TableColumnProjection.Column(payload.columns().getFirst().key(),"来源",120.0,"text",null)),
                List.of(Map.of("__lineId",selectedId))));
        var selected=selection.select(payload.columns(),payload.rows());selection.verifyComplete();
        assertEquals(1,selected.size());assertEquals(selectedId,selected.getFirst().get("__lineId"));
        assertEquals(new BigDecimal("5.0001"),selected.getFirst().get(numeric));
    }
    private record Rows(List<String> columns,List<Map<String,Object>> rows) { }

    private static final class Fixture {
        final EntityManager em=mock(EntityManager.class);
        final FinanceReportService finance;
        final StockReportService stock;
        String dataSql;
        Fixture(boolean physical) {
            when(em.createNativeQuery(anyString())).thenAnswer(call->{
                String sql=call.getArgument(0);var query=mock(Query.class,RETURNS_SELF);
                when(query.getSingleResult()).thenReturn(0L);
                when(query.getResultList()).thenAnswer(ignored->{
                    var fields=fields(sql);if(fields.isEmpty())return List.of();
                    dataSql=sql;
                    var first=values(fields,FIRST,sql);
                    return physical?List.of(first,values(fields,SECOND,sql)):Collections.singletonList(first);
                });return query;
            });
            var access=mock(FinanceDocumentAccessPolicy.class);
            when(access.scope()).thenReturn(new OwnerVisibility.OwnerScope(true,Set.of()));
            when(access.nativeReadScope(anyString(),anyString(),any(OwnerVisibility.OwnerScope.class))).thenReturn(new DocumentAccessPolicy.NativeReadScope("1=1",null,Set.of()));
            when(access.hasAuthority(anyString())).thenReturn(true);
            var settings=mock(SystemSettingsService.class);when(settings.readInt(any())).thenReturn(50_000);
            finance=new FinanceReportService(em,access,settings,mock(FinanceStatementService.class),mock(FinanceCostService.class),
                    mock(GlReportService.class),mock(FixedAssetService.class),mock(PartyMonthlySummaryService.class));
            stock=new StockReportService(em,settings,mock(StockQueryService.class),mock(StockCostMasker.class));
        }
        Rows financeRows(String report) {
            var value=switch(report) {
                case "ar-ap/detail"->finance.arApDetail("AR",null,null,null,null,null,null,Map.of(),1,50,null,null);
                case "ar-ap/order-plan"->finance.salesOrderReceivablePlan(null,null,null,null,null,1,50,null,null);
                case "receipt/detail"->finance.receiptDetail(null,null,null,null,null,null,null,Map.of(),1,50,null,null);
                case "expense/detail"->finance.expenseDetail(null,null,null,null,null,null,null,Map.of(),1,50,null,null);
                case "expense/summary"->finance.expenseSummary(null,null,null,null,null,null,Map.of(),1,50,null,null);
                case "income/detail"->finance.incomeDetail(null,null,null,null,null,null,null,Map.of(),1,50,null,null);
                case "income/summary"->finance.incomeSummary(null,null,null,null,null,null,Map.of(),1,50,null,null);
                case "fee-offset/detail"->finance.feeOffsetDetail(null,null,null,null,null,null,null,Map.of(),1,50,null,null);
                case "bank/detail"->finance.bankReport("detail",null,null,null,null,null,Map.of(),1,50,null,null);
                case "party/flow"->finance.partyStatementFlow(HEADER,"AR",null,null,1,50,Map.of(),null,null);
                case "party/detail"->finance.partyStatementDetail(HEADER,"AR",null,null,1,50,Map.of(),null,null);
                default->throw new AssertionError(report);
            };
            return new Rows(value.columns().stream().map(column->column.key()).toList(),value.rows());
        }
    }

    private static List<String> fields(String sql) {
        var aliases=Pattern.compile("finance_source\\(([^)]+)\\)").matcher(sql);
        if(aliases.find()) {
            return Arrays.stream(aliases.group(1).split(",")).map(value->value.replace("\"","").trim()).toList();
        }
        if(!sql.startsWith("SELECT ")||sql.startsWith("SELECT count")||sql.startsWith("SELECT COUNT"))return List.of();
        int end=sql.indexOf(" FROM (");
        if(sql.contains("AS \"__lineId\"")&&sql.contains("\"eventOrder\"::text")) {
            var result=new ArrayList<String>();
            for(String value:sql.substring(7,end).split(",")) {
                if(value.contains("AS \"__lineId\"")){result.add("__lineId");continue;}
                var key=Pattern.compile("\"([^\"]+)\"").matcher(value);assertTrue(key.find(),value);result.add(key.group(1));
            }
            return result;
        }
        var from=Pattern.compile("\\bFROM\\b",Pattern.CASE_INSENSITIVE).matcher(sql);
        if(!from.find())return List.of();
        var named=Pattern.compile("\\bAS\\s+\"([^\"]+)\"",Pattern.CASE_INSENSITIVE).matcher(sql.substring(0,from.start()));
        var result=new ArrayList<String>();
        while(named.find()) { result.add(named.group(1)); }
        return result;
    }
    private static Object[] values(List<String> keys,UUID id,String sql) {
        var result=new Object[keys.size()];
        Set<String> numbers=Set.of("qty","drawQty","returnQty","actualQty","amount","amountOriginal","orderOriginal",
                "amountLocal","lineAmount","incomeAmount","writeOffOriginal","salesOriginal");
        for(int index=0;index<keys.size();index++) {
            String key=keys.get(index);
            result[index]=key.equals("__lineId")?(sql.contains("\"eventOrder\"::text")?"10:"+id:id)
                    :key.equals("__srcId")?HEADER:key.equals("billDate")?Date.valueOf("2026-10-11")
                    :numbers.contains(key)?new BigDecimal("5.0001"):null;
        }
        return result;
    }
}
