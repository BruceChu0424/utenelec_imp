package com.uten.imp.features.subcontract.short_delivery;

import com.uten.imp.common.util.NumericColumnFilter;
import com.uten.imp.common.util.TaskKeywordSearch;
import com.uten.imp.common.util.SqlColumnSearch;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.Query;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/** Header reads over the same authorized case facts as list/count/candidates. */
record SubcontractShortDeliveryTableQuery(Map<String, String> filters) {
    static final Map<String, String> TEXT = Map.ofEntries(
            Map.entry("orderBillNo", "c.order_bill_no_snapshot"),
            Map.entry("supplierName", "supplier.name"),
            Map.entry("goodsName", "COALESCE(c.goods_name_snapshot, goods.name)"),
            Map.entry("goodsCode", "COALESCE(c.goods_code_snapshot, goods.code)"),
            Map.entry("colorName", "color.name"),
            Map.entry("receiptBillNo", "c.receipt_bill_no_snapshot"),
            Map.entry("wasteBillNo", "waste.bill_no"),
            Map.entry("ownerName", "COALESCE(header_owner.full_name,header_legacy_owner.full_name)"));
    static final Map<String, String> NUMERIC = Map.ofEntries(
            Map.entry("orderedQty", "c.ordered_qty"), Map.entry("allowedLossPct", "c.allowed_loss_pct"),
            Map.entry("floorQty", "c.floor_qty"), Map.entry("deliveredQty", "c.delivered_qty"),
            Map.entry("shortfallQty", "c.shortfall_qty"), Map.entry("shortfallPct", "c.shortfall_pct"),
            Map.entry("arrivalCount", "c.arrival_count"), Map.entry("lossQty", "c.loss_qty"),
            Map.entry("lossPct", "c.loss_pct"));
    private static final Map<String, SqlColumnSearch.Field> DATES = Map.of(
            "detectedAt", SqlColumnSearch.Field.instant("c.detected_at"),
            "closedAt", SqlColumnSearch.Field.instant("c.closed_at"),
            "expectedCompleteBy", SqlColumnSearch.Field.calendarDate("c.expected_complete_by"));
    static final Map<String, String> EXACT = Map.of(
            "severity", "c.severity", "status", "(" + SubcontractShortDeliveryService.EFFECTIVE_STATUS_SQL + ")");
    private static final Map<String, String> SORT = sortFields();
    private static Map<String, String> sortFields() {
        Map<String, String> fields = new LinkedHashMap<>(TEXT);
        fields.putAll(NUMERIC);
        DATES.forEach((key, field) -> fields.put(key, field.expression()));
        return Map.copyOf(fields);
    }

    SubcontractShortDeliveryTableQuery {
        Map<String, String> safe = new LinkedHashMap<>();
        if (filters != null) filters.forEach((key, raw) -> {
            if (!key.startsWith("search.") && !key.startsWith("f.")) return;
            String column = key.substring(key.indexOf('.') + 1);
            boolean exact = key.startsWith("f.");
            if (exact ? !EXACT.containsKey(column) : !TEXT.containsKey(column) && !NUMERIC.containsKey(column) && !DATES.containsKey(column))
                throw invalid();
            if (raw == null || raw.isBlank()) return;
            String value = raw.strip();
            if (value.length() > 500) throw invalid();
            if (NUMERIC.containsKey(column)) NumericColumnFilter.parse(value);
            if (DATES.containsKey(column)) {
                if (value.length() > 128) throw invalid();
                SqlColumnSearch.criteria(Map.of(column, value), DATES);
            }
            if (exact && !("severity".equals(column)
                    ? Set.of("SEVERE", "BELOW_FLOOR", "WITHIN_TOLERANCE", "UNSET_TOLERANCE")
                    : Set.of("PENDING_OWNER", "WAITING_MORE", "ACCEPTED_LOSS", "COMPLETED", "CANCELED")).contains(value))
                throw invalid();
            safe.put(key, value);
        });
        filters = Map.copyOf(safe);
    }

    String sql(String excludedColumn) {
        StringBuilder sql = new StringBuilder();
        filters.forEach((key, value) -> {
            String column = key.substring(key.indexOf('.') + 1);
            if (column.equals(excludedColumn) || DATES.containsKey(column)) return;
            String parameter = "short_header_" + column;
            sql.append(" AND ");
            if (key.startsWith("f.")) sql.append(EXACT.get(column)).append(" = :").append(parameter);
            else if (NUMERIC.containsKey(column)) sql.append(NumericColumnFilter.parse(value).sql(NUMERIC.get(column), parameter));
            else sql.append(" ").append(TaskKeywordSearch.conditionParameter(parameter, TEXT.get(column)));
        });
        var dates = dates(excludedColumn);
        if (!dates.parameters().isEmpty()) sql.append(" AND (").append(dates.predicate()).append(")");
        return sql.toString();
    }

    void bind(Query query, String excludedColumn) {
        filters.forEach((key, value) -> {
            String column = key.substring(key.indexOf('.') + 1);
            if (column.equals(excludedColumn) || DATES.containsKey(column)) return;
            String parameter = "short_header_" + column;
            if (NUMERIC.containsKey(column)) NumericColumnFilter.parse(value).bind(parameter, query::setParameter);
            else query.setParameter(parameter, value);
        });
        dates(excludedColumn).bind(query);
    }

    private SqlColumnSearch.Criteria dates(String excludedColumn) {
        Map<String, String> dates = new LinkedHashMap<>();
        filters.forEach((key, value) -> {
            String column = key.substring(key.indexOf('.') + 1);
            if (DATES.containsKey(column) && !column.equals(excludedColumn)) dates.put(column, value);
        });
        return SqlColumnSearch.criteria(dates, DATES, "short_dates_");
    }

    static String orderBy(String column, String direction, String fallback) {
        if (column == null || column.isBlank()) return fallback;
        String expression = SORT.get(column);
        if (expression == null || direction != null && !Set.of("asc", "desc").contains(direction.toLowerCase(java.util.Locale.ROOT)))
            throw invalid();
        return expression + ("desc".equalsIgnoreCase(direction) ? " DESC" : " ASC") + " NULLS LAST, " + fallback;
    }

    private static ApiException invalid() {
        return new ApiException(ErrorCode.VALIDATION_FAILED, "短交表头筛选或排序条件无效，请核对后重试");
    }
}
