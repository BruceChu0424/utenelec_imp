package com.uten.imp.audit;

import java.util.Locale;
import java.util.Set;
import java.util.regex.Pattern;

/** One reviewed source of truth for successful automatic request noise. */
final class AuditNoisePolicy {

    private static final Set<String> AUTOMATIC_READ_PATHS = Set.of(
            "/api/settings/public",
            "/api/auth/me",
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
            "/api/sales/orders/progress/stage-counts",
            "/api/warehouse/inbound/expectations/type-counts");
    private static final Set<String> AUTOMATIC_SESSION_WRITE_PATHS = Set.of(
            "/api/auth/refresh",
            "/api/visitor/auth/refresh",
            "/api/notices/read-by-source");
    private static final String HEARTBEAT_PREFIX = "/api/task-claims/";
    private static final String HEARTBEAT_SUFFIX = "/heartbeat";
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
                && AUTOMATIC_READ_PATHS.contains(path))
                || ("POST".equals(method)
                && (AUTOMATIC_SESSION_WRITE_PATHS.contains(path)
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
