package com.uten.imp.common.report;

import com.uten.imp.common.finance.ProcurementDeliveryDifference;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.purchase.report.PurchaseReportService;
import com.uten.imp.features.subcontract.report.SubcontractReportService;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/** Exercise each actual report query builder before its shared SQL execution. */
class ProcurementReportDifferenceFilterTest {
    private record Captured(String projection, ReportQueryKit.WhereBuilder.Built predicate) {}

    @ParameterizedTest
    @ValueSource(strings = {"purchase-order", "purchase-request", "purchase-expediting", "subcontract-order"})
    void differenceHeaderUsesTheProjectedBusinessExpressionBeforePagination(String report) {
        Captured captured = capture(report, Map.of("search.differenceQty", "-10.0000000001..0.0000000001"));
        String expression = report.equals("purchase-request")
                ? ProcurementDeliveryDifference.balanceSql(
                    "(i.qty+CASE WHEN i.quantity_semantics='CHARGED_PLUS_GIFT_V1' THEN i.gift_qty ELSE 0 END)",
                    "(i.ordered_qty+i.gift_ordered_qty)")
                : ProcurementDeliveryDifference.sql("i.qty", "i.received_qty", "i.returned_qty");
        assertTrue(captured.projection.contains(expression + " AS \"differenceQty\""));
        assertTrue(captured.predicate.sql().contains("(" + expression + ") BETWEEN"
                + " :column_numeric_differenceQty_lower AND :column_numeric_differenceQty_upper"));
        assertEquals(new BigDecimal("-10.0000000001"),
                captured.predicate.params().get("column_numeric_differenceQty_lower"));
        assertEquals(new BigDecimal("0.0000000001"),
                captured.predicate.params().get("column_numeric_differenceQty_upper"));
        assertFalse(captured.predicate.sql().contains("LIMIT"));
    }

    @ParameterizedTest
    @ValueSource(strings = {"purchase-order", "purchase-request", "purchase-expediting", "subcontract-order"})
    void invalidHeaderQueryCannotReachExecution(String report) {
        assertThrows(ApiException.class,
                () -> capture(report, Map.of("search.differenceQty", "0 OR 1=1")));
        assertThrows(ApiException.class,
                () -> capture(report, Map.of("search.differenceQty", "2..-1")));
        Captured unfiltered = capture(report, Map.of());
        assertFalse(unfiltered.predicate.params().containsKey("column_numeric_differenceQty"));
        assertFalse(unfiltered.predicate.sql().contains("column_numeric_differenceQty"));
    }

    private static Captured capture(String report, Map<String, String> filters) {
        if (report.equals("subcontract-order")) {
            CapturingSubcontract service = new CapturingSubcontract();
            service.orderDetail(null, null, null, null, null, null, filters, 2, 1, "differenceQty", "desc");
            return service.captured;
        }
        CapturingPurchase service = new CapturingPurchase();
        switch (report) {
            case "purchase-order" -> service.orderDetail(null, null, null, null, null, null,
                    filters, 2, 1, "differenceQty", "desc");
            case "purchase-request" -> service.requestDetail(null, null, null, null, null,
                    filters, 2, 1, "differenceQty", "desc");
            case "purchase-expediting" -> service.expediting(null, null, null, null, null,
                    filters, 2, 1, "differenceQty", "desc");
            default -> throw new IllegalArgumentException(report);
        }
        return service.captured;
    }

    private static class CapturingPurchase extends PurchaseReportService {
        Captured captured;
        CapturingPurchase() { super(null, null); }
        @Override
        public com.uten.imp.features.purchase.report.ReportTableResponse execute(
                List<com.uten.imp.features.purchase.report.ReportColumn> columns,
                String select, String from, ReportQueryKit.WhereBuilder where, String orderBy,
                List<ReportQueryKit.FacetSpec> specs, Map<String, String> filters,
                int page, int size, String sort, String order) {
            return execute(columns, select, from, where, orderBy, specs, filters, page, size, sort, order, Map.of());
        }
        @Override
        public com.uten.imp.features.purchase.report.ReportTableResponse execute(
                List<com.uten.imp.features.purchase.report.ReportColumn> columns,
                String select, String from, ReportQueryKit.WhereBuilder where, String orderBy,
                List<ReportQueryKit.FacetSpec> specs, Map<String, String> filters,
                int page, int size, String sort, String order, Map<String, String> overrides) {
            Map<String, String> types = new java.util.LinkedHashMap<>();
            columns.forEach(column -> types.put(column.key(), column.type()));
            ProcurementReportColumnSearch.apply(where, filters, types, overrides);
            captured = new Captured(select, where.build(null));
            return null;
        }
    }

    private static class CapturingSubcontract extends SubcontractReportService {
        Captured captured;
        CapturingSubcontract() { super(null, null); }
        @Override
        public com.uten.imp.features.subcontract.report.ReportTableResponse execute(
                List<com.uten.imp.features.subcontract.report.ReportColumn> columns,
                String select, String from, ReportQueryKit.WhereBuilder where, String orderBy,
                List<ReportQueryKit.FacetSpec> specs, Map<String, String> filters,
                int page, int size, String sort, String order) {
            return execute(columns, select, from, where, orderBy, specs, filters, page, size, sort, order, Map.of());
        }
        @Override
        public com.uten.imp.features.subcontract.report.ReportTableResponse execute(
                List<com.uten.imp.features.subcontract.report.ReportColumn> columns,
                String select, String from, ReportQueryKit.WhereBuilder where, String orderBy,
                List<ReportQueryKit.FacetSpec> specs, Map<String, String> filters,
                int page, int size, String sort, String order, Map<String, String> overrides) {
            Map<String, String> types = new java.util.LinkedHashMap<>();
            columns.forEach(column -> types.put(column.key(), column.type()));
            ProcurementReportColumnSearch.apply(where, filters, types, overrides);
            captured = new Captured(select, where.build(null));
            return null;
        }
    }
}
