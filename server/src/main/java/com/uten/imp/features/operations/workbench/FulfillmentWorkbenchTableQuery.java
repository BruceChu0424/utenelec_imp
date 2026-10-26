package com.uten.imp.features.operations.workbench;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.Query;

import java.time.LocalDate;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Whitelisted table controls; values are always bound separately from SQL. */
public record FulfillmentWorkbenchTableQuery(
        String sort, String order, Map<String, String> filters,
        LocalDate issuedFrom, LocalDate issuedTo, LocalDate needFrom, LocalDate needTo) {
    static final String NULL_VALUE = "__null__";
    static final Map<String, String> FIELDS = Map.of(
            "planNo", "NULLIF(plan_no,'')", "docNo", "visible_doc_no",
            "goods", "goods_id::text", "spec", "NULLIF(concat_ws(' / ',NULLIF(spec,''),NULLIF(color_name,'')),'')",
            "status", "display_stage", "needDate", "need_date::text",
            "issuedAt", "(issued_at AT TIME ZONE 'Asia/Shanghai')::date::text",
            "supplierName", "NULLIF(supplier_name,'')");
    /** Text searches are separate from exact facet values (notably the goods UUID). */
    static final Map<String, String> SEARCH_FIELDS = Map.ofEntries(
            Map.entry("planNo", "plan_no"), Map.entry("docNo", "visible_doc_no"),
            Map.entry("goods", "goods_name"),
            Map.entry("goodsCode", "goods_code"), Map.entry("colorName", "color_name"),
            Map.entry("spec", "spec"), Map.entry("supplierName", "supplier_name"),
            Map.entry("warehouseName", "warehouse_name"));
    /**
     * 只能排序、不做列筛选/分面的列(生产领料任务中心 2026-09-24 表头排序: 发料仓、待领数量)。
     * 不进 {@link #FIELDS}: 那张表同时决定分面查询要算哪些列, 加进去会让采购/委外每次多算两组分面。
     */
    static final Map<String, String> SORT_ONLY_FIELDS = Map.of(
            "warehouseName", "NULLIF(warehouse_name,'')", "openQty", "open_qty",
            "differenceQty", "difference_qty");
    private record FilterField(String key, String expression, String parameter, boolean search) {}
    private static final List<FilterField> FILTER_FIELDS = filterFields();

    private static List<FilterField> filterFields() {
        Map<String, String> fields = new java.util.TreeMap<>(FIELDS);
        SEARCH_FIELDS.forEach((key, expression) -> fields.put("search." + key, expression));
        List<FilterField> result = new java.util.ArrayList<>();
        fields.forEach((key, expression) -> result.add(
                new FilterField(key, expression, "filter_" + result.size(), key.startsWith("search."))));
        return List.copyOf(result);
    }

    public FulfillmentWorkbenchTableQuery {
        sort = sort == null || sort.isBlank() ? "needDate" : sort.strip();
        order = order == null || order.isBlank() ? "asc" : order.strip().toLowerCase(java.util.Locale.ROOT);
        if (!FIELDS.containsKey(sort) && !SORT_ONLY_FIELDS.containsKey(sort)
                || !java.util.Set.of("asc", "desc").contains(order)) {
            throw invalid("工作台排序字段或方向无效");
        }
        Map<String, String> safe = new LinkedHashMap<>();
        if (filters != null) filters.forEach((key, value) -> {
            if (!(key.startsWith("search.") ? SEARCH_FIELDS.containsKey(key.substring(7)) : FIELDS.containsKey(key)))
                throw invalid("工作台列筛选字段无效: " + key);
            if (value != null && !value.isBlank()) {
                if (value.length() > 500) throw invalid("工作台列筛选值过长");
                safe.put(key, value.strip());
            }
        });
        filters = Map.copyOf(safe);
        if (issuedFrom != null && issuedTo != null && issuedFrom.isAfter(issuedTo)
                || needFrom != null && needTo != null && needFrom.isAfter(needTo)) {
            throw invalid("工作台日期范围无效");
        }
    }

    public static FulfillmentWorkbenchTableQuery from(
            String sort, String order, Map<String, String> params,
            LocalDate issuedFrom, LocalDate issuedTo, LocalDate needFrom, LocalDate needTo) {
        Map<String, String> filters = new LinkedHashMap<>();
        params.forEach((key, value) -> {
            if (key.startsWith("f.")) filters.put(key.substring(2), value);
            else if (key.startsWith("search.")) filters.put(key, value);
        });
        return new FulfillmentWorkbenchTableQuery(sort, order, filters, issuedFrom, issuedTo, needFrom, needTo);
    }

    String filterSql(String excludedField) {
        StringBuilder sql = new StringBuilder();
        for (FilterField field : FILTER_FIELDS) {
            String value = filters.get(field.key());
            if (value == null || field.key().equals(excludedField)) continue;
            if (field.search()) {
                sql.append(" AND ").append(com.uten.imp.common.util.TaskKeywordSearch.conditionParameter(
                        field.parameter(), field.expression()));
            } else {
                sql.append(" AND ").append(field.expression());
                sql.append(NULL_VALUE.equals(value) ? " IS NULL" : " = :" + field.parameter());
            }
        }
        return sql.toString();
    }

    String rangeSql() {
        String sql = "";
        if (issuedFrom != null) sql += " AND (issued_at AT TIME ZONE 'Asia/Shanghai')::date >= :issued_from";
        if (issuedTo != null) sql += " AND (issued_at AT TIME ZONE 'Asia/Shanghai')::date <= :issued_to";
        if (needFrom != null) sql += " AND need_date >= :need_from";
        if (needTo != null) sql += " AND need_date <= :need_to";
        return sql;
    }

    void bind(Query query) {
        bindFilters(query, null);
        if (issuedFrom != null) query.setParameter("issued_from", issuedFrom);
        if (issuedTo != null) query.setParameter("issued_to", issuedTo);
        if (needFrom != null) query.setParameter("need_from", needFrom);
        if (needTo != null) query.setParameter("need_to", needTo);
    }

    void bindFilters(Query query, String excludedField) {
        for (FilterField field : FILTER_FIELDS) {
            String value = filters.get(field.key());
            if (value == null || field.key().equals(excludedField)) continue;
            if (field.search() || !NULL_VALUE.equals(value)) query.setParameter(field.parameter(), value);
        }
    }

    String orderSql() {
        String direction = "desc".equals(order) ? "DESC" : "ASC";
        String expression = switch (sort) {
            case "goods" -> "goods_code " + direction + " NULLS LAST, goods_name";
            case "issuedAt" -> "issued_at";
            case "needDate" -> "need_date";
            default -> FIELDS.containsKey(sort) ? FIELDS.get(sort) : SORT_ONLY_FIELDS.get(sort);
        };
        return expression + " " + direction + " NULLS LAST, task_id";
    }

    private static ApiException invalid(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }
}
