package com.uten.imp.features.operations.workbench;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.Query;

import java.time.LocalDate;
import java.util.LinkedHashMap;
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
            "issuedAt", "(issued_at AT TIME ZONE 'Asia/Shanghai')::date::text");

    public FulfillmentWorkbenchTableQuery {
        sort = sort == null || sort.isBlank() ? "needDate" : sort.strip();
        order = order == null || order.isBlank() ? "asc" : order.strip().toLowerCase(java.util.Locale.ROOT);
        if (!FIELDS.containsKey(sort) || !java.util.Set.of("asc", "desc").contains(order)) {
            throw invalid("工作台排序字段或方向无效");
        }
        Map<String, String> safe = new LinkedHashMap<>();
        if (filters != null) filters.forEach((key, value) -> {
            if (!FIELDS.containsKey(key)) throw invalid("工作台列筛选字段无效: " + key);
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
        params.forEach((key, value) -> { if (key.startsWith("f.")) filters.put(key.substring(2), value); });
        return new FulfillmentWorkbenchTableQuery(sort, order, filters, issuedFrom, issuedTo, needFrom, needTo);
    }

    String filterSql(String excludedField) {
        StringBuilder sql = new StringBuilder();
        filters.entrySet().stream().sorted(Map.Entry.comparingByKey()).forEach(entry -> {
            if (entry.getKey().equals(excludedField)) return;
            String field = FIELDS.get(entry.getKey());
            sql.append(" AND ").append(field);
            sql.append(NULL_VALUE.equals(entry.getValue()) ? " IS NULL" : " = :f_" + entry.getKey());
        });
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
        filters.forEach((key, value) -> { if (!NULL_VALUE.equals(value)) query.setParameter("f_" + key, value); });
        if (issuedFrom != null) query.setParameter("issued_from", issuedFrom);
        if (issuedTo != null) query.setParameter("issued_to", issuedTo);
        if (needFrom != null) query.setParameter("need_from", needFrom);
        if (needTo != null) query.setParameter("need_to", needTo);
    }

    String orderSql() {
        String expression = switch (sort) {
            case "goods" -> "goods_code " + order + " NULLS LAST, goods_name";
            case "issuedAt" -> "issued_at";
            case "needDate" -> "need_date";
            default -> FIELDS.get(sort);
        };
        return expression + " " + order + " NULLS LAST, task_id";
    }

    private static ApiException invalid(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }
}
