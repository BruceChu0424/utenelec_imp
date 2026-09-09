package com.uten.imp.audit;

import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Pattern;

/** One reviewed source of truth for successful automatic request noise. */
final class AuditNoisePolicy {

    private static final Set<String> AUTOMATIC_READ_PATHS = Set.of(
            "/api/admin/server-status",
            "/api/settings/public",
            "/api/auth/me",
            "/api/master/goods/facets",
            "/api/master/goods/lookup",
            "/api/master/clients/facets",
            "/api/master/clients/dict",
            "/api/master/suppliers/facets",
            "/api/master/suppliers/dict",
            "/api/master/accounts/facets",
            "/api/master/accounts/summary",
            "/api/master/accounts/dict",
            "/api/master/currencies/facets",
            "/api/master/currencies/dict",
            "/api/master/warehouses/facets",
            "/api/master/warehouses/dict",
            "/api/master/units/facets",
            "/api/master/units/dict",
            "/api/master/colors/facets",
            "/api/master/colors/dict",
            "/api/master/moulds/facets",
            "/api/master/client-categories/tree",
            "/api/master/supplier-categories/tree",
            "/api/master/material-categories/tree",
            "/api/master/mould-categories/tree",
            "/api/master/payment-styles/tree",
            "/api/org/departments/tree",
            "/api/org/departments/employee-picker-tree",
            "/api/my-department/tree",
            "/api/notices/arrivals",
            "/api/notices/unread-count",
            "/api/notices/unread-count-by-source",
            "/api/finance/procurement-approvals/count",
            "/api/finance/procurement-approvals/type-counts",
            "/api/sales/orders/finance-confirmation/count",
            "/api/warehouse/inbound/expectations/count",
            "/api/warehouse/inbound/arrival-exceptions/count",
            "/api/warehouse/production-finished-in/tasks/count",
            "/api/production/quality-inspections/count",
            "/api/production/quality-replenishments/material-tasks/count",
            "/api/warehouse/subcontract-outbound/tasks/count",
            "/api/procurement/inspection/pending-count",
            "/api/procurement/arrival-exceptions/count",
            "/api/finance/procurement-arrival-exceptions/count",
            "/api/org/hr-tasks/count",
            "/api/rd-tasks/count",
            "/api/visitor-approval/pending-count",
            "/api/visitor-approval/host-pending-count",
            "/api/hr/profile-changes/pending-count",
            "/api/operations/workbench/purchase/count",
            "/api/operations/workbench/subcontract/count",
            "/api/operations/workbench/warehouse/count",
            "/api/production/schedule/pending-count",
            "/api/sales/orders/stats",
            "/api/sales/orders/progress",
            "/api/sales/orders/progress/stage-counts",
            "/api/production/plans/progress",
            "/api/production/plans/progress/summary",
            "/api/production/plans/progress/workshops",
            "/api/production/quality-inspections/capability",
            "/api/purchase/orders/last-suppliers",
            "/api/subcontract/orders/last-suppliers",
            "/api/warehouse/inbound/expectations/type-counts");
    private static final Set<String> AUTOMATIC_SESSION_WRITE_PATHS = Set.of(
            "/api/auth/refresh",
            "/api/visitor/auth/refresh",
            "/api/notices/read-by-source");
    private static final String HEARTBEAT_PREFIX = "/api/task-claims/";
    private static final String HEARTBEAT_SUFFIX = "/heartbeat";
    private static final String UUID_PATH_SEGMENT =
            "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-"
                    + "[0-9a-f]{4}-[0-9a-f]{12}";
    private static final String UUID_SQL_LIKE_SEGMENT =
            "________-____-____-____-____________";
    private static final List<Pattern> AUTOMATIC_READ_PATH_PATTERNS = List.of(
            Pattern.compile("^/api/sales/orders/" + UUID_PATH_SEGMENT
                    + "/(?:plan-progress|progress-timeline)$"),
            Pattern.compile("^/api/sales/returns/" + UUID_PATH_SEGMENT
                    + "/quality$"),
            Pattern.compile("^/api/subcontract/orders/" + UUID_PATH_SEGMENT
                    + "/(?:cost-items|progress)$"),
            Pattern.compile("^/api/production/material-analyses/" + UUID_PATH_SEGMENT
                    + "/materials/" + UUID_PATH_SEGMENT + "/supply-progress$"));
    private static final List<Pattern> AUTOMATIC_SESSION_WRITE_PATH_PATTERNS = List.of(
            Pattern.compile("^/api/payroll/slips/" + UUID_PATH_SEGMENT + "/view$"));
    private static final List<String> AUTOMATIC_READ_SQL_LIKE_PATTERNS = List.of(
            "/api/sales/orders/" + UUID_SQL_LIKE_SEGMENT + "/plan-progress",
            "/api/sales/orders/" + UUID_SQL_LIKE_SEGMENT + "/progress-timeline",
            "/api/sales/returns/" + UUID_SQL_LIKE_SEGMENT + "/quality",
            "/api/subcontract/orders/" + UUID_SQL_LIKE_SEGMENT + "/cost-items",
            "/api/subcontract/orders/" + UUID_SQL_LIKE_SEGMENT + "/progress",
            "/api/production/material-analyses/" + UUID_SQL_LIKE_SEGMENT
                    + "/materials/" + UUID_SQL_LIKE_SEGMENT + "/supply-progress");
    private static final List<String> AUTOMATIC_SESSION_WRITE_SQL_LIKE_PATTERNS = List.of(
            "/api/payroll/slips/" + UUID_SQL_LIKE_SEGMENT + "/view");
    private static final Pattern TASK_CLAIM_HEARTBEAT = Pattern.compile(
            "^/api/task-claims/[^/]+/[^/]+/heartbeat$");

    private AuditNoisePolicy() {
    }

    static boolean isAutomaticOperation(String methodValue, String pathValue) {
        String method = methodValue == null
                ? ""
                : methodValue.trim().toUpperCase(Locale.ROOT);
        String path = normalizedPath(pathValue);
        return (("GET".equals(method) || "HEAD".equals(method))
                && (AUTOMATIC_READ_PATHS.contains(path)
                || AUTOMATIC_READ_PATH_PATTERNS.stream()
                .anyMatch(pattern -> pattern.matcher(path).matches())))
                || ("POST".equals(method)
                && (AUTOMATIC_SESSION_WRITE_PATHS.contains(path)
                || AUTOMATIC_SESSION_WRITE_PATH_PATTERNS.stream()
                .anyMatch(pattern -> pattern.matcher(path).matches())
                || TASK_CLAIM_HEARTBEAT.matcher(path).matches()));
    }

    static boolean isSuccessfulStoredAutomaticRequest(AuditLog value) {
        if (value == null
                || !"request".equals(normalized(value.getEventSource()))
                || !isAutomaticOperation(value.getHttpMethod(), value.getHttpPath())
                || value.getStatusCode() != null && value.getStatusCode() >= 400) {
            return false;
        }
        String result = normalized(value.getResult());
        String mainCode = result.split(";", 2)[0].trim();
        return "success".equals(mainCode) || "succeeded".equals(mainCode);
    }

    static Set<String> automaticReadPaths() {
        return AUTOMATIC_READ_PATHS;
    }

    static Set<String> automaticSessionWritePaths() {
        return AUTOMATIC_SESSION_WRITE_PATHS;
    }

    static List<String> automaticReadSqlLikePatterns() {
        return AUTOMATIC_READ_SQL_LIKE_PATTERNS;
    }

    static List<String> automaticSessionWriteSqlLikePatterns() {
        return AUTOMATIC_SESSION_WRITE_SQL_LIKE_PATTERNS;
    }

    static String heartbeatSqlLikePattern() {
        return HEARTBEAT_PREFIX + "%" + HEARTBEAT_SUFFIX;
    }

    private static String normalizedPath(String path) {
        if (path == null) {
            return "";
        }
        String value = path.trim().toLowerCase(Locale.ROOT);
        return value.length() > 1 && value.endsWith("/")
                ? value.substring(0, value.length() - 1)
                : value;
    }

    private static String normalized(String value) {
        return value == null ? "" : value.trim().toLowerCase(Locale.ROOT);
    }
}
