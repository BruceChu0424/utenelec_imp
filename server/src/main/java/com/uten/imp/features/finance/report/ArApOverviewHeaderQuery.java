package com.uten.imp.features.finance.report;

import com.uten.imp.common.util.SqlColumnSearch;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.util.*;

/** The six visible Z facts, evaluated after each party's local-currency balance aggregate. */
final class ArApOverviewHeaderQuery {
    private static final Map<String, SqlColumnSearch.Field> FIELDS = Map.of(
            "partyName", SqlColumnSearch.Field.text("partyName"),
            "partyType", SqlColumnSearch.Field.text("partyType"),
            "receivable", SqlColumnSearch.Field.decimal("receivable"),
            "payable", SqlColumnSearch.Field.decimal("payable"),
            "phone", SqlColumnSearch.Field.text("phone"),
            "address", SqlColumnSearch.Field.text("address"));
    private final Map<String, String> filters;
    ArApOverviewHeaderQuery(Map<String, String> filters) { this.filters = filters == null ? Map.of() : Map.copyOf(filters); }
    Set<String> keys() { return FIELDS.keySet(); }
    void apply(FinanceReportService.FinanceWhereBuilder where) {
        var inputs = new LinkedHashMap<String, String>();
        filters.forEach((key, value) -> {
            if (key.startsWith("search.")) inputs.put(key.substring(7), value);
            else if (!key.equals("partyType")) throw invalid("总览筛选列无效");
        });
        var criteria = SqlColumnSearch.criteria(inputs, FIELDS, "overview_header_");
        where.add(criteria.predicate(), null, null);
        criteria.parameters().forEach((key, value) -> where.add(null, key, value));
        String type = filters.get("partyType");
        if (type != null && !type.isBlank()) {
            if (!Set.of("客户", "供应商").contains(type)) throw invalid("往来单位类型无效");
            where.add("partyType=:overview_party_type", "overview_party_type", type);
        }
    }
    String ordering(String sort, String order) {
        if (sort == null || sort.isBlank()) return null;
        if (!FIELDS.containsKey(sort)) throw invalid("总览排序列无效");
        if (order != null && !Set.of("asc", "desc").contains(order)) throw invalid("排序方向无效");
        return FIELDS.get(sort).expression() + ("desc".equals(order) ? " DESC" : " ASC") + " NULLS LAST,partyType,partyName,partyId";
    }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }
}
