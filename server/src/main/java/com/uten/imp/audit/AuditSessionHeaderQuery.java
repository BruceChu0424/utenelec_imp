package com.uten.imp.audit;

import com.uten.imp.common.util.ColumnKeywordSearch;
import com.uten.imp.common.util.JpaColumnSearch;
import com.uten.imp.common.util.KeywordSearch;
import com.uten.imp.common.util.NumericColumnFilter;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.Query;
import jakarta.servlet.http.HttpServletRequest;
import java.util.Map;
import java.util.Set;

/** Filters complete, snapshot-bounded session facts, never a page of already grouped sessions. */
public record AuditSessionHeaderQuery(Map<String, String> values, String sort, boolean ascending,
                                      java.time.OffsetDateTime evaluatedAt) {
    public AuditSessionHeaderQuery(Map<String, String> values, String sort, boolean ascending) {
        this(values, sort, ascending, java.time.OffsetDateTime.now(com.uten.imp.common.time.BusinessTime.ZONE));
    }
    public static final AuditSessionHeaderQuery EMPTY = new AuditSessionHeaderQuery(Map.of(), null, true);
    private static final Map<String, String> NUMBERS = Map.of("operations", "h.operation_count",
            "failures", "h.failure_count", "postLogout", "h.post_logout_count");
    private static final Map<String, String> DATES = Map.of("login", "h.login_at", "logout",
            "COALESCE(h.logout_at,h.last_activity_at,h.first_activity_at)");
    private static final String DEVICE = "concat_ws(' ', h.device_name, h.device_model, h.device_platform)";
    static final String STATUS = "CASE WHEN h.post_logout_count>0 THEN 'activity_after_logout' "
            + "WHEN h.security_termination_count>0 THEN 'security_terminated' "
            + "WHEN h.logout_at IS NOT NULL THEN 'normal_logout' ELSE 'no_logout_record' END";
    static final String CREDENTIAL = "CASE WHEN h.refresh_expires_at IS NULL AND h.refresh_revoked_at IS NULL THEN 'no_record' "
            + "WHEN h.refresh_revoked_at IS NOT NULL THEN 'revoked' WHEN h.refresh_expires_at<=:header_now THEN 'expired' "
            + "WHEN h.refresh_expires_at IS NOT NULL THEN 'not_expired' ELSE 'unknown' END";
    private static final Set<String> FIELDS = Set.of("status", "credential", "device", "operations", "failures",
            "postLogout", "login", "logout");
    private static final Set<String> SORTS = Set.of("device", "operations", "failures", "postLogout", "login", "logout");

    public AuditSessionHeaderQuery {
        values = Map.copyOf(ColumnKeywordSearch.validate(values, FIELDS));
        if (sort != null && !SORTS.contains(sort)) throw invalid();
        values.forEach((key, value) -> {
            if (NUMBERS.containsKey(key)) NumericColumnFilter.parse(value);
            else if (DATES.containsKey(key)) JpaColumnSearch.businessDateBounds(value);
            else if (key.equals("status") && !Set.of("activity_after_logout", "security_terminated", "normal_logout", "no_logout_record").contains(value)) throw invalid();
            else if (key.equals("credential") && !Set.of("no_record", "revoked", "expired", "not_expired", "unknown").contains(value)) throw invalid();
        });
    }

    static AuditSessionHeaderQuery from(HttpServletRequest request) {
        if (request == null) return EMPTY;
        String sort = request.getParameter("sort");
        String order = request.getParameter("order");
        if (sort != null && sort.isBlank()) sort = null;
        if (sort != null && !("asc".equalsIgnoreCase(order) || "desc".equalsIgnoreCase(order))) throw invalid();
        return new AuditSessionHeaderQuery(ColumnKeywordSearch.requestValues(request), sort, "asc".equalsIgnoreCase(order));
    }

    boolean active() { return !values.isEmpty() || sort != null; }

    String where() {
        StringBuilder result = new StringBuilder("TRUE");
        values.forEach((key, value) -> {
            String parameter = "header_" + key;
            result.append(" AND (");
            if (NUMBERS.containsKey(key)) result.append(NumericColumnFilter.parse(value).sql(NUMBERS.get(key), parameter));
            else if (DATES.containsKey(key)) result.append(DATES.get(key)).append(" >= :").append(parameter).append("_from AND ")
                    .append(DATES.get(key)).append(" < :").append(parameter).append("_to");
            else if (key.equals("device")) result.append(KeywordSearch.nativeCondition(value, parameter,
                    "h.device_name", "h.device_model", "h.device_platform"));
            else result.append(key.equals("status") ? STATUS : CREDENTIAL).append(" = :").append(parameter);
            result.append(")");
        });
        return result.toString();
    }

    void bind(Query query, java.time.OffsetDateTime now) {
        values.forEach((key, value) -> {
            String parameter = "header_" + key;
            if (NUMBERS.containsKey(key)) NumericColumnFilter.parse(value).bind(parameter, query::setParameter);
            else if (DATES.containsKey(key)) {
                var bounds = JpaColumnSearch.businessDateBounds(value);
                query.setParameter(parameter + "_from", bounds.from());
                query.setParameter(parameter + "_to", bounds.toExclusive());
            } else if (key.equals("device")) KeywordSearch.bindNative(query, value, parameter);
            else query.setParameter(parameter, value);
        });
        if (values.containsKey("credential")) query.setParameter("header_now", now);
    }

    String order() {
        if (sort == null) return "COALESCE(h.login_at,h.first_activity_at) DESC, h.session_id DESC";
        String expression = NUMBERS.containsKey(sort) ? NUMBERS.get(sort) : DATES.containsKey(sort) ? DATES.get(sort) : DEVICE;
        return expression + (ascending ? " ASC" : " DESC") + " NULLS LAST, h.session_id DESC";
    }

    private static ApiException invalid() {
        return new ApiException(ErrorCode.VALIDATION_FAILED, "审计会话表头条件无效");
    }
}
