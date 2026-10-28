package com.uten.imp.features.operations.workbench;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.util.NumericColumnFilter;
import jakarta.persistence.Query;

import java.time.LocalDate;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Whitelisted table controls; values are always bound separately from SQL. */
public record FulfillmentWorkbenchTableQuery(
        String sort, String order, Map<String, String> filters,
        LocalDate issuedFrom, LocalDate issuedTo, LocalDate needFrom, LocalDate needTo,
        boolean operationsProjection, boolean explicitSort) {
    public FulfillmentWorkbenchTableQuery(String sort,String order,Map<String,String> filters,
            LocalDate issuedFrom,LocalDate issuedTo,LocalDate needFrom,LocalDate needTo) {
        this(sort,order,filters,issuedFrom,issuedTo,needFrom,needTo,false,sort!=null&&!sort.isBlank());
    }
    public FulfillmentWorkbenchTableQuery forOperationsProjection() {
        return operationsProjection?this:new FulfillmentWorkbenchTableQuery(sort,order,filters,issuedFrom,issuedTo,needFrom,needTo,true,explicitSort);
    }
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
            Map.entry("warehouseName", "warehouse_name"),
            Map.entry("needDate", "need_date::text"),
            Map.entry("issuedAt", "(issued_at AT TIME ZONE 'Asia/Shanghai')::date::text"),
            Map.entry("source", "visible_doc_no"));
    // A grouped/hidden difference is unknown, just as in the rendered row. Never
    // let a header query infer a masked fact or compare a sum of mixed units.
    private static final String VISIBLE_NUMBER = "(CASE WHEN visible_doc_no IS NOT NULL AND COALESCE(goods_count,0)<=1"
            + " AND COALESCE(open_line_count,0)<=1 AND COALESCE(cardinality(action_item_ids),0)<=1 THEN %s END)";
    static final Map<String, String> NUMERIC_SEARCH_FIELDS = Map.ofEntries(
            Map.entry("differenceQty", VISIBLE_NUMBER.formatted("difference_qty")),
            Map.entry("requiredQty", "required_qty"),
            Map.entry("openQty", "open_qty"),
            Map.entry("allocatedQty", "allocated_qty"), Map.entry("fulfilledQty", "fulfilled_qty"),
            Map.entry("orderableQty", VISIBLE_NUMBER.formatted("orderable_qty")),
            Map.entry("orderQty", VISIBLE_NUMBER.formatted("allocated_qty")),
            // The pending application cell offers navigation here, not a quantity.
            Map.entry("drawnQty", "NULL::numeric"), Map.entry("pendingQty", "NULL::numeric"),
            Map.entry("drawableQty", "NULL::numeric"), Map.entry("shortQty", "NULL::numeric"));
    /**
     * 排序字段；不自动建立分面。差异数另走 NUMERIC_SEARCH_FIELDS 的精确数值条件。
     * 不进 {@link #FIELDS}: 那张表同时决定分面查询要算哪些列, 加进去会让采购/委外每次多算两组分面。
     */
    static final Map<String, String> SORT_ONLY_FIELDS = Map.ofEntries(
            Map.entry("warehouseName", "NULLIF(warehouse_name,'')"), Map.entry("openQty", "open_qty"),
            Map.entry("differenceQty", "difference_qty"), Map.entry("goodsCode", "goods_code"),
            Map.entry("requiredQty", "required_qty"), Map.entry("orderableQty", "orderable_qty"),
            Map.entry("allocatedQty", "allocated_qty"), Map.entry("fulfilledQty", "fulfilled_qty"),
            Map.entry("expectedDate", "expected_date"),
            Map.entry("colorName", "color_name"), Map.entry("source", "visible_doc_no"),
            Map.entry("orderQty", "allocated_qty"), Map.entry("drawnQty", "NULL::numeric"),
            Map.entry("pendingQty", "NULL::numeric"), Map.entry("drawableQty", "NULL::numeric"),
            Map.entry("shortQty", "NULL::numeric"));
    private record FilterField(String key, String expression, String parameter, boolean search) {}
    private static final List<FilterField> FILTER_FIELDS = filterFields();
    private static final Map<String,com.uten.imp.common.util.SqlColumnSearch.Field> DATE_SEARCH_FIELDS=Map.of(
            "needDate",com.uten.imp.common.util.SqlColumnSearch.Field.calendarDate("need_date"),
            "issuedAt",com.uten.imp.common.util.SqlColumnSearch.Field.instant("issued_at"),
            "expectedDate",com.uten.imp.common.util.SqlColumnSearch.Field.calendarDate("expected_date"));
    private static final String OPERATION_QUANTITY="(CASE WHEN COALESCE(goods_count,0)<=1 AND COALESCE(open_line_count,0)<=1"
            +" AND COALESCE(cardinality(action_item_ids),0)<=1 AND upper(COALESCE(task_status,''))<>'MATERIALS_TO_DEFINE'"
            +" AND upper(COALESCE(action_doc_type,''))<>'MATERIAL_DISCOVERY' THEN %s END)";
    private String numericExpression(String key) {
        String expression=NUMERIC_SEARCH_FIELDS.get(key);
        return operationsProjection&&java.util.Set.of("requiredQty","allocatedQty","fulfilledQty","openQty").contains(key)
                ?OPERATION_QUANTITY.formatted(expression):expression;
    }
    private static boolean dateSlot(String key) {return key.startsWith("search.")&&DATE_SEARCH_FIELDS.containsKey(key.substring(7));}
    private com.uten.imp.common.util.SqlColumnSearch.Criteria dates(String excludedField) {
        Map<String,String> requested=new LinkedHashMap<>();
        for(String key:List.of("needDate","issuedAt","expectedDate")) {
            String value=filters.get("search."+key);
            if(value!=null&&!key.equals(excludedField)&&!("search."+key).equals(excludedField))requested.put(key,value);
        }
        return com.uten.imp.common.util.SqlColumnSearch.criteria(requested,DATE_SEARCH_FIELDS,"workbench_dates_");
    }

    private static List<FilterField> filterFields() {
        Map<String, String> fields = new java.util.TreeMap<>(FIELDS);
        SEARCH_FIELDS.forEach((key, expression) -> fields.put("search." + key, expression));
        // Preserve existing parameter identities while extending date controls.
        fields.remove("search.needDate");
        fields.remove("search.issuedAt");
        fields.remove("search.source");
        List<FilterField> result = new java.util.ArrayList<>();
        fields.forEach((key, expression) -> result.add(
                new FilterField(key, expression, "filter_" + result.size(), key.startsWith("search."))));
        for (String key : List.of("issuedAt", "needDate", "source"))
            result.add(new FilterField("search." + key, SEARCH_FIELDS.get(key), "filter_" + result.size(), true));
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
            if (!(key.startsWith("search.") ? SEARCH_FIELDS.containsKey(key.substring(7))
                    || NUMERIC_SEARCH_FIELDS.containsKey(key.substring(7))||DATE_SEARCH_FIELDS.containsKey(key.substring(7)) : FIELDS.containsKey(key)))
                throw invalid("工作台列筛选字段无效: " + key);
            if (value != null && !value.isBlank()) {
                if (value.length() > 500) throw invalid("工作台列筛选值过长");
                if (key.startsWith("search.") && NUMERIC_SEARCH_FIELDS.containsKey(key.substring(7)))
                    NumericColumnFilter.parse(value);
                if(dateSlot(key))com.uten.imp.common.util.JpaColumnSearch.businessDateBounds(value);
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
            if (value == null || field.key().equals(excludedField)||dateSlot(field.key())) continue;
            if (field.search()) {
                sql.append(" AND ").append(com.uten.imp.common.util.TaskKeywordSearch.conditionParameter(
                        field.parameter(), field.expression()));
            } else {
                sql.append(" AND ").append(field.expression());
                sql.append(NULL_VALUE.equals(value) ? " IS NULL" : " = :" + field.parameter());
            }
        }
        NUMERIC_SEARCH_FIELDS.forEach((key, expression) -> {
            String value = filters.get("search." + key);
            if (value != null && !key.equals(excludedField) && !("search." + key).equals(excludedField))
                sql.append(" AND ").append(NumericColumnFilter.parse(value).sql(numericExpression(key), "numeric_" + key));
        });
        var dates=dates(excludedField);
        if(!dates.parameters().isEmpty())sql.append(" AND (").append(dates.predicate()).append(")");
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
            if (value == null || field.key().equals(excludedField)||dateSlot(field.key())) continue;
            if (field.search() || !NULL_VALUE.equals(value)) query.setParameter(field.parameter(), value);
        }
        NUMERIC_SEARCH_FIELDS.forEach((key, expression) -> {
            String value = filters.get("search." + key);
            if (value != null && !key.equals(excludedField) && !("search." + key).equals(excludedField))
                NumericColumnFilter.parse(value).bind("numeric_" + key, query::setParameter);
        });
        dates(excludedField).bind(query);
    }

    String orderSql() {
        String direction = "desc".equals(order) ? "DESC" : "ASC";
        String expression = switch (sort) {
            case "goods" -> "goods_code " + direction + " NULLS LAST, goods_name";
            case "issuedAt" -> "issued_at";
            case "needDate" -> "need_date";
            default -> FIELDS.containsKey(sort) ? FIELDS.get(sort) : SORT_ONLY_FIELDS.get(sort);
        };
        if(operationsProjection&&NUMERIC_SEARCH_FIELDS.containsKey(sort))expression=numericExpression(sort);
        return expression + " " + direction + " NULLS LAST, task_id";
    }

    private static ApiException invalid(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }
}
