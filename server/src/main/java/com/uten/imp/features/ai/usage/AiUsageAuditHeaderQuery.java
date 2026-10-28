package com.uten.imp.features.ai.usage;

import com.uten.imp.common.util.ColumnKeywordSearch;
import com.uten.imp.common.util.JpaColumnSearch;
import com.uten.imp.common.util.KeywordSearch;
import com.uten.imp.common.util.NumericColumnFilter;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/** Conditions on the already redacted event projection, before aggregates and page boundaries. */
final class AiUsageAuditHeaderQuery {
    private static final Map<String, String> TEXT = Map.of(
            "person", "concat_ws(' ', e.name, e.code)", "question", "e.question",
            "provider", "array_to_string(e.provider_names, ' / ')", "model", "array_to_string(e.models, ' / ')");
    private static final Map<String, String> NUMBERS = Map.of(
            "calls", "e.calls", "inputTokens", "e.input_tokens", "outputTokens", "e.output_tokens");
    private static final Set<String> ALLOWED = Set.of("person", "question", "provider", "model", "calls",
            "inputTokens", "outputTokens", "time", "status", "purpose", "cost");
    private static final Map<String, String> SORT = Map.ofEntries(
            Map.entry("time", "e.created_at"), Map.entry("person", "lower(e.name)"),
            Map.entry("question", "lower(e.question)"), Map.entry("provider", TEXT.get("provider")),
            Map.entry("model", TEXT.get("model")), Map.entry("calls", "e.calls"),
            Map.entry("inputTokens", "e.input_tokens"), Map.entry("outputTokens", "e.output_tokens"));
    private static final Set<String> SPECIFIC_PURPOSES = Set.of("query_goods_cost", "inventory_lookup",
            "query_client_credit", "SALES_ORDER", "SALES_QUOTE", "EXPENSE_CLAIM", "production_in_progress",
            "workbench_tasks", "feature_directory", "my_access", "sales_order_progress", "purchase_order_status",
            "subcontract_order_status", "PAGE_HELP", "PAGE_STATE", "ACTION", "prepare_permission_grant");

    static String conditions(Map<String, String> input, MapSqlParameterSource parameters) {
        var values = ColumnKeywordSearch.validate(input, ALLOWED);
        StringBuilder where = new StringBuilder("TRUE");
        values.forEach((key, value) -> {
            String parameter = "header_" + key;
            where.append(" AND (");
            if (TEXT.containsKey(key)) {
                where.append(KeywordSearch.nativeCondition(value, parameter, TEXT.get(key)));
                Map<String, Object> bindings = new LinkedHashMap<>();
                KeywordSearch.bindNative(bindings, value, parameter);
                bindings.forEach(parameters::addValue);
            } else if (NUMBERS.containsKey(key)) {
                var query = NumericColumnFilter.parse(value);
                where.append(query.sql(NUMBERS.get(key), parameter));
                query.bind(parameter, parameters::addValue);
            } else if (key.equals("time")) {
                var range = JpaColumnSearch.businessDateBounds(value);
                where.append("e.created_at >= :header_time_from AND e.created_at < :header_time_to ");
                parameters.addValue("header_time_from", range.from()).addValue("header_time_to", range.toExclusive());
            } else if (key.equals("status")) {
                if (!Set.of("SUCCEEDED", "FAILED", "CANCELLED", "QUEUED", "RUNNING").contains(value)) throw invalid();
                where.append(value.equals("QUEUED") ? "e.status IN ('QUEUED','PENDING')" : "e.status = :header_status");
                parameters.addValue(parameter, value);
            } else if (key.equals("purpose")) {
                // The UI distinguishes a specific recorded tool from a kind fallback.
                if (value.startsWith("kind:")) {
                    where.append(value.equals("kind:OTHER")
                            ? "e.kind NOT IN ('ERP_CHAT','ERP_DOCUMENT_ROUTE','SALES_DOCUMENT_INTAKE')"
                            : "e.kind = :header_purpose");
                    where.append(" AND coalesce(e.intent,'') NOT IN (:specific_purpose_intents)");
                    parameters.addValue("specific_purpose_intents", SPECIFIC_PURPOSES);
                } else {
                    if (!SPECIFIC_PURPOSES.contains(value)) throw invalid();
                    where.append("e.intent = :header_purpose ");
                }
                parameters.addValue(parameter, value.startsWith("kind:") ? value.substring(5) : value);
            } else if (key.equals("cost")) {
                where.append(switch (value) {
                    case "pending" -> "e.unknown_cost > 0";
                    case "local" -> "e.local_use";
                    case "actual" -> "EXISTS (SELECT 1 FROM period_calls c WHERE c.event_id=e.id AND c.basis='ACTUAL' AND c.amount IS NOT NULL)";
                    case "estimated" -> "EXISTS (SELECT 1 FROM period_calls c WHERE c.event_id=e.id AND c.basis='ESTIMATED' AND c.amount IS NOT NULL)";
                    default -> throw invalid();
                });
            }
            where.append(")");
        });
        return where.toString();
    }

    static String order(String sort, String order) {
        if (sort == null || sort.isBlank()) return "e.created_at DESC, e.id DESC";
        String expression = SORT.get(sort);
        if (expression == null || !("asc".equalsIgnoreCase(order) || "desc".equalsIgnoreCase(order))) throw invalid();
        return expression + ("asc".equalsIgnoreCase(order) ? " ASC" : " DESC") + " NULLS LAST, e.id DESC";
    }

    private static ApiException invalid() {
        return new ApiException(ErrorCode.VALIDATION_FAILED, "AI 使用记录表头条件无效");
    }
}
