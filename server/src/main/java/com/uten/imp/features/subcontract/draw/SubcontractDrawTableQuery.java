package com.uten.imp.features.subcontract.draw;

import com.uten.imp.common.util.NumericColumnFilter;
import com.uten.imp.common.util.TaskKeywordSearch;
import com.uten.imp.common.util.SqlColumnSearch;
import com.uten.imp.common.util.ColumnKeywordSearch;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.Query;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;

/**
 * Conditions use classified task facts before either count or pagination.
 *
 * <p>表头精确值筛选({@code f.{key}})按 {@link #EXACT} 白名单: 2026-10-30 起不再只有颜色——
 * 任务中心「待处理」拍平表(申请行+领料行两车道)的名称类列(委外商/来源计划/单据号/委外件/颜色)
 * 都按当前数据汇总候选值, 领料车道与工作台车道同 key 同语义。{@code spec} 领料行恒空
 * (与申请行合并分面时全部归入空值桶, 选定某规格值即排除全部领料行, 与行内显示一致)。
 */
record SubcontractDrawTableQuery(String sort, String order, Map<String, String> filters) {
    static final Map<String, String> TEXT = Map.ofEntries(
            Map.entry("planNo", "plan_no"), Map.entry("docNo", "order_bill_no"),
            Map.entry("goods", "goods_name"), Map.entry("goodsCode", "goods_code"),
            Map.entry("supplierName", "supplier_name"), Map.entry("colorName", "color_name"),
            Map.entry("spec", "NULL::text"));
    /** 表头精确值筛选: key → classified CTE 的取值表达式(与服务端分面同源)。 */
    static final Map<String, String> EXACT = Map.ofEntries(
            Map.entry("colorName", "NULLIF(color_name, '')"),
            Map.entry("supplierName", "NULLIF(supplier_name, '')"),
            Map.entry("planNo", "NULLIF(plan_no, '')"),
            Map.entry("docNo", "NULLIF(order_bill_no, '')"),
            Map.entry("goods", "goods_id::text"),
            Map.entry("spec", "NULL::text"),
            Map.entry("status", "status"));
    /** {@code f.status} 只接受领料行状态档, 不收任意文本。 */
    static final Set<String> STATUS_VALUES = Set.of(
            "DRAWABLE", "DRAWABLE_PARTIAL", "DRAW_SUBMITTED", "WAITING_PLANNING", "WAITING_MATERIAL");
    static final Map<String, String> NUMERIC = Map.ofEntries(
            Map.entry("requiredQty", "order_qty"), Map.entry("differenceQty", "difference_qty"),
            Map.entry("openQty", "0::numeric"), Map.entry("orderableQty", "0::numeric"),
            Map.entry("orderQty", "order_qty"), Map.entry("drawnQty", "drawn_qty"),
            Map.entry("pendingQty", "pending_qty"), Map.entry("drawableQty", "drawable_qty"),
            Map.entry("shortQty", "short_qty"));
    private static final Map<String, SqlColumnSearch.Field> DATES = Map.of(
            "needDate", SqlColumnSearch.Field.calendarDate("deliver_date"),
            "issuedAt", SqlColumnSearch.Field.instant("NULL::timestamptz"));
    /** 有序白名单快照: SQL 文本与参数名只从这些常量派生, 顺序与 JVM/调用方无关。 */
    private static final Map<String, String> EXACT_SORTED = sortedCopy(EXACT);
    private static final Map<String, String> TEXT_SORTED = sortedCopy(TEXT);
    private static final Map<String, String> NUMERIC_SORTED = sortedCopy(NUMERIC);

    private static Map<String, String> sortedCopy(Map<String, String> source) {
        return Collections.unmodifiableMap(new TreeMap<>(source));
    }

    private static final Set<String> SEARCH_FIELDS=java.util.stream.Stream.of(TEXT.keySet(),NUMERIC.keySet(),DATES.keySet())
            .flatMap(Set::stream).collect(java.util.stream.Collectors.toUnmodifiableSet());
    static final String NULL_VALUE = "__null__";

    SubcontractDrawTableQuery {
        Map<String, String> safe = new LinkedHashMap<>();
        if (sort != null && !sort.isBlank() && !TEXT.containsKey(sort) && !NUMERIC.containsKey(sort) && !DATES.containsKey(sort)) throw invalid();
        if (order != null && !Set.of("asc", "desc").contains(order.toLowerCase(java.util.Locale.ROOT))) throw invalid();
        if (filters != null) filters.forEach((key, raw) -> {
            if (key.startsWith("f.")) {
                String column = key.substring(2);
                if (!EXACT.containsKey(column)) throw invalid();
                if (raw == null || raw.isBlank()) return;
                if (raw.length() > 500) throw invalid();
                String value = raw.strip();
                if ("status".equals(column) && !STATUS_VALUES.contains(value)) throw invalid();
                safe.put(key, value);
                return;
            }
            if (!key.startsWith("search.")) return;
            String column = ColumnKeywordSearch.declaredKey(key.substring(7),SEARCH_FIELDS);
            if (column==null) throw invalid();
            if (raw == null || raw.isBlank()) return;
            String value = raw.strip();
            if (value.length() > 500) throw invalid();
            if (NUMERIC.containsKey(column)) NumericColumnFilter.parse(value);
            if (DATES.containsKey(column)) {
                if (value.length() > 128) throw invalid();
                SqlColumnSearch.criteria(Map.of(column, value), DATES);
            }
            safe.put("search."+column, value);
        });
        filters = Map.copyOf(safe);
    }

    String sql(boolean canViewDifference) {
        return sql(canViewDifference, null);
    }

    String sql(boolean canViewDifference, String excludedColumn) {
        // 白名单驱动迭代: 表达式与参数名全部来自静态常量, 用户值只经 :parameter 绑定;
        // 片段顺序按白名单排序固定(不随请求键序或 JVM 哈希盐变化)。
        StringBuilder sql = new StringBuilder();
        EXACT_SORTED.forEach((column, expression) -> {
            String value = filters.get("f." + column);
            if (value == null || column.equals(excludedColumn)) return;
            sql.append(NULL_VALUE.equals(value)
                    ? " AND (" + expression + ") IS NULL"
                    : " AND (" + expression + ") = :draw_exact_" + column);
        });
        NUMERIC_SORTED.forEach((column, expression) -> {
            String value = filters.get("search." + column);
            if (value == null || column.equals(excludedColumn)) return;
            String number = "differenceQty".equals(column) && !canViewDifference ? "NULL::numeric" : expression;
            sql.append(" AND ").append(NumericColumnFilter.parse(value).sql(number, "draw_header_" + column));
        });
        TEXT_SORTED.forEach((column, expression) -> {
            String value = filters.get("search." + column);
            if (value == null || column.equals(excludedColumn)) return;
            sql.append(" AND ").append(TaskKeywordSearch.conditionParameter("draw_header_" + column, expression));
        });
        var dates = dates();
        if (!dates.parameters().isEmpty()) sql.append(" AND (").append(dates.predicate()).append(")");
        return sql.toString();
    }

    void bind(Query query) {
        EXACT_SORTED.forEach((column, expression) -> {
            String value = filters.get("f." + column);
            if (value != null && !NULL_VALUE.equals(value)) query.setParameter("draw_exact_" + column, value);
        });
        NUMERIC_SORTED.forEach((column, expression) -> {
            String value = filters.get("search." + column);
            if (value != null) NumericColumnFilter.parse(value).bind("draw_header_" + column, query::setParameter);
        });
        TEXT_SORTED.forEach((column, expression) -> {
            String value = filters.get("search." + column);
            if (value != null) query.setParameter("draw_header_" + column, value);
        });
        dates().bind(query);
    }

    private SqlColumnSearch.Criteria dates() {
        Map<String, String> dates = new LinkedHashMap<>();
        DATES.keySet().stream().sorted().forEach(column -> {
            String value = filters.get("search." + column);
            if (value != null) dates.put(column, value);
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
