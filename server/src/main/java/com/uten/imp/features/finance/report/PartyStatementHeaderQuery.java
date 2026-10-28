package com.uten.imp.features.finance.report;

import com.uten.imp.common.util.SqlColumnSearch;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.util.*;

/** Conditions over the completed statement projection, after chronological balances. */
final class PartyStatementHeaderQuery {
    static final Set<String> ORIGINAL_AMOUNTS = Set.of("salesOriginal", "receiptOriginal", "balanceOriginal");
    private final Map<String, SqlColumnSearch.Field> fields;
    private final Map<String, String> filters;
    private final boolean annual;

    PartyStatementHeaderQuery(Map<String, String> filters, boolean annual, boolean simple) {
        this.filters = filters == null ? Map.of() : Map.copyOf(filters);
        this.annual = annual;
        var declared = new LinkedHashMap<String, SqlColumnSearch.Field>();
        if (annual) {
            declared.put("ym", SqlColumnSearch.Field.calendarDate("to_date(report.ym,'YYYY-MM')"));
            for (String key : List.of("prevBalance", "posted", "settled", "balance"))
                declared.put(key, SqlColumnSearch.Field.decimal(expression(key)));
        } else {
            declared.put("billDate", SqlColumnSearch.Field.calendarDate(expression("billDate")));
            for (String key : List.of("refNo", "currencyCode", "originalStatus"))
                declared.put(key, SqlColumnSearch.Field.text(expression(key)));
            if (!simple) for (String key : List.of("type", "remark"))
                declared.put(key, SqlColumnSearch.Field.text(expression(key)));
            for (String key : List.of("salesOriginal", "salesRate", "salesLocal", "receiptOriginal",
                    "receiptRate", "receiptLocal", "balanceOriginal", "balanceRate", "balanceLocal"))
                declared.put(key, SqlColumnSearch.Field.decimal(expression(key)));
        }
        fields = Map.copyOf(declared);
        for (String key : this.filters.keySet()) {
            if (key.equals("keyword") && !annual) continue;
            if (key.startsWith("search.") ? !fields.containsKey(key.substring(7))
                    : annual || !Set.of("currencyCode", "originalStatus", "type").contains(key)
                        || simple && key.equals("type")) throw invalid("此列不支持对账条件");
        }
        if (this.filters.entrySet().stream().anyMatch(entry -> entry.getKey().startsWith("search.")
                && ORIGINAL_AMOUNTS.contains(entry.getKey().substring(7))
                && entry.getValue() != null && !entry.getValue().isBlank())) requireCurrency();
    }

    Set<String> keys() { return fields.keySet(); }

    SqlColumnSearch.Criteria criteria() {
        var inputs = new LinkedHashMap<String, String>();
        filters.forEach((key, value) -> { if (key.startsWith("search.")) inputs.put(key.substring(7), value); });
        var typed = SqlColumnSearch.criteria(inputs, fields, "party_header_");
        var parameters = new LinkedHashMap<>(typed.parameters());
        StringBuilder predicate = new StringBuilder("(").append(typed.predicate()).append(')');
        String keyword = filters.get("keyword");
        if (keyword != null && !keyword.isBlank()) {
            var global = SqlColumnSearch.criteria(Map.of("refNo",keyword),
                    Map.of("refNo",SqlColumnSearch.Field.text(expression("refNo"))),"party_keyword_");
            predicate.append(" AND (").append(global.predicate()).append(')');
            parameters.putAll(global.parameters());
        }
        for (String key : List.of("currencyCode", "originalStatus", "type")) {
            String value = filters.get(key);
            if (value == null || value.isBlank()) continue;
            if (key.equals("currencyCode")) {
                if (value.equals("__null__")) predicate.append(" AND report.\"__currencyId\" IS NULL");
                else {
                    predicate.append(" AND report.\"__currencyId\"=:party_header_currency");
                    parameters.put("party_header_currency", currencyId(value));
                }
            } else {
                predicate.append(" AND ").append(expression(key)).append("=:party_header_").append(key);
                parameters.put("party_header_" + key, value);
            }
        }
        return new SqlColumnSearch.Criteria(predicate.toString(), Map.copyOf(parameters));
    }

    String orderBy(String key, String direction) {
        String fallback = annual ? "report.ym" : "report.\"billDate\",report.\"eventOrder\",report.\"refNo\",report.\"eventId\"";
        if (key == null || key.isBlank()) return fallback;
        if (!fields.containsKey(key)) return fallback; // An old saved view may retain a retired column.
        if (direction != null && !Set.of("asc", "desc").contains(direction)) throw invalid("排序方向无效");
        if (ORIGINAL_AMOUNTS.contains(key)) requireCurrency();
        return fields.get(key).expression() + ("desc".equals(direction) ? " DESC" : " ASC") + " NULLS LAST," + fallback;
    }

    PartyStatementHeaderQuery withoutFacet(String key, boolean simple) {
        var remaining = new LinkedHashMap<>(filters);
        remaining.remove(key);
        remaining.remove("search." + key);
        if (key.equals("currencyCode")) ORIGINAL_AMOUNTS.forEach(amount -> remaining.remove("search." + amount));
        return new PartyStatementHeaderQuery(remaining, annual, simple);
    }

    private void requireCurrency() {
        String currency = filters.get("currencyCode");
        if (currency == null || currency.equals("__null__")) throw invalid("请先选择一个币别，再比较或排序原币金额");
        currencyId(currency);
    }
    static Map<String,String> withKeyword(Map<String,String> filters,String keyword) {
        if (keyword == null || keyword.isBlank()) return filters == null ? Map.of() : filters;
        var result = new LinkedHashMap<>(filters == null ? Map.<String,String>of() : filters);
        result.put("keyword",keyword);
        return result;
    }
    private static UUID currencyId(String value) {
        try { return UUID.fromString(value); }
        catch (IllegalArgumentException error) { throw invalid("币别筛选无效"); }
    }
    private static String expression(String key) { return "report.\"" + key + "\""; }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }
}
