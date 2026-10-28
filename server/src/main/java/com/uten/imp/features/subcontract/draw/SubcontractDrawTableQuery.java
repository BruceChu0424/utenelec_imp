package com.uten.imp.features.subcontract.draw;

import com.uten.imp.common.util.NumericColumnFilter;
import com.uten.imp.common.util.TaskKeywordSearch;
import com.uten.imp.common.util.SqlColumnSearch;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.Query;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/** Conditions use classified task facts before either count or pagination. */
record SubcontractDrawTableQuery(String sort, String order, Map<String, String> filters) {
    static final Map<String, String> TEXT = Map.ofEntries(
            Map.entry("planNo", "plan_no"), Map.entry("docNo", "order_bill_no"),
            Map.entry("goods", "goods_name"), Map.entry("goodsCode", "goods_code"),
            Map.entry("supplierName", "supplier_name"), Map.entry("colorName", "color_name"),
            Map.entry("spec", "NULL::text"));
    static final Map<String, String> NUMERIC = Map.ofEntries(
            Map.entry("requiredQty", "order_qty"), Map.entry("differenceQty", "difference_qty"),
            Map.entry("openQty", "0::numeric"), Map.entry("orderableQty", "0::numeric"),
            Map.entry("orderQty", "order_qty"), Map.entry("drawnQty", "drawn_qty"),
            Map.entry("pendingQty", "pending_qty"), Map.entry("drawableQty", "drawable_qty"),
            Map.entry("shortQty", "short_qty"));
    private static final Map<String, SqlColumnSearch.Field> DATES = Map.of(
            "needDate", SqlColumnSearch.Field.calendarDate("deliver_date"),
            "issuedAt", SqlColumnSearch.Field.instant("NULL::timestamptz"));

    SubcontractDrawTableQuery {
        Map<String, String> safe = new LinkedHashMap<>();
        if (sort != null && !sort.isBlank() && !TEXT.containsKey(sort) && !NUMERIC.containsKey(sort) && !DATES.containsKey(sort)) throw invalid();
        if (order != null && !Set.of("asc", "desc").contains(order.toLowerCase(java.util.Locale.ROOT))) throw invalid();
        if (filters != null) filters.forEach((key, raw) -> {
            if (key.equals("f.colorName")) {
                if (raw != null && !raw.isBlank()) {
                    if (raw.length() > 500) throw invalid();
                    safe.put(key, raw.strip());
                }
                return;
            }
            if (!key.startsWith("search.")) return;
            String column = key.substring(7);
            if (!TEXT.containsKey(column) && !NUMERIC.containsKey(column) && !DATES.containsKey(column)) throw invalid();
            if (raw == null || raw.isBlank()) return;
            String value = raw.strip();
            if (value.length() > 500) throw invalid();
            if (NUMERIC.containsKey(column)) NumericColumnFilter.parse(value);
            if (DATES.containsKey(column)) {
                if (value.length() > 128) throw invalid();
                SqlColumnSearch.criteria(Map.of(column, value), DATES);
            }
            safe.put(key, value);
        });
        filters = Map.copyOf(safe);
    }

    String sql(boolean canViewDifference) {
        return sql(canViewDifference, null);
    }

    String sql(boolean canViewDifference, String excludedColumn) {
        StringBuilder sql = new StringBuilder();
        filters.forEach((key, value) -> {
            if (key.equals("f.colorName")) {
                if (!"colorName".equals(excludedColumn)) sql.append("__null__".equals(value)
                        ? " AND NULLIF(color_name, '') IS NULL" : " AND color_name = :draw_exact_colorName");
                return;
            }
            String column = key.substring(7), parameter = "draw_header_" + column;
            if (column.equals(excludedColumn)) return;
            if (DATES.containsKey(column)) return;
            String number = "differenceQty".equals(column) && !canViewDifference ? "NULL::numeric" : NUMERIC.get(column);
            sql.append(" AND ").append(NUMERIC.containsKey(column)
                    ? NumericColumnFilter.parse(value).sql(number, parameter)
                    : TaskKeywordSearch.conditionParameter(parameter, TEXT.get(column)));
        });
        var dates = dates();
        if (!dates.parameters().isEmpty()) sql.append(" AND (").append(dates.predicate()).append(")");
        return sql.toString();
    }

    void bind(Query query) {
        filters.forEach((key, value) -> {
            if (key.equals("f.colorName")) {
                if (!"__null__".equals(value)) query.setParameter("draw_exact_colorName", value);
                return;
            }
            String column = key.substring(7), parameter = "draw_header_" + column;
            if (DATES.containsKey(column)) return;
            if (NUMERIC.containsKey(column)) NumericColumnFilter.parse(value).bind(parameter, query::setParameter);
            else query.setParameter(parameter, value);
        });
        dates().bind(query);
    }

    private SqlColumnSearch.Criteria dates() {
        Map<String, String> dates = new LinkedHashMap<>();
        filters.forEach((key, value) -> {
            if (!key.startsWith("search.")) return;
            String column = key.substring(7);
            if (DATES.containsKey(column)) dates.put(column, value);
        });
        return SqlColumnSearch.criteria(dates, DATES, "draw_dates_");
    }

    String orderSql() {
        return orderSql("");
    }

    String orderSql(String prefix) {
        String fallback = prefix + "status_rank, " + prefix + "deliver_date ASC NULLS LAST, "
                + prefix + "order_bill_no, " + prefix + "line_no ASC NULLS LAST, " + prefix + "order_item_id";
        if (sort == null || sort.isBlank()) return fallback;
        String expression = DATES.containsKey(sort) ? DATES.get(sort).expression() : NUMERIC.getOrDefault(sort, TEXT.get(sort));
        if (!expression.startsWith("NULL::") && !expression.startsWith("0::")) expression = prefix + expression;
        return expression + ("desc".equalsIgnoreCase(order) ? " DESC" : " ASC") + " NULLS LAST, " + fallback;
    }

    private static ApiException invalid() {
        return new ApiException(ErrorCode.VALIDATION_FAILED, "委外领料表头查询条件无效，请核对后重试");
    }
}
