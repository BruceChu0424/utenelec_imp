package com.uten.imp.audit;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import java.util.Locale;
import java.util.Set;
import java.util.UUID;

/**
 * Correlates the request-level operation row with database-trigger detail rows.
 *
 * <p>The identifier is internal metadata only. It never contains a token,
 * request body or user-provided value.
 */
public final class AuditRequestContext {

    public static final String REQUEST_ID_ATTRIBUTE = "uten.audit.requestId";
    public static final String RESPONSE_REQUEST_ID_HEADER =
            "X-Uten-Audit-Request-Id";
    public static final String VERIFIED_ACTOR_ATTRIBUTE =
            "uten.audit.verifiedActor";
    public static final String SESSION_ID_ATTRIBUTE =
            "uten.audit.sessionId";
    static final String OPERATION_START_NANOS_ATTRIBUTE =
            "uten.audit.operationStartNanos";
    static final String OPERATION_RECORDED_ATTRIBUTE =
            "uten.audit.operationRecorded";
    static final String MEANINGFUL_EVENT_RECORDED_ATTRIBUTE =
            "uten.audit.meaningfulEventRecorded";
    private static final Set<String> AUDITED_METHODS =
            Set.of("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD");

    private AuditRequestContext() {
    }

    public static UUID ensureRequestId(HttpServletRequest request) {
        Object existing = request.getAttribute(REQUEST_ID_ATTRIBUTE);
        if (existing instanceof UUID value) {
            return value;
        }
        UUID value = UUID.randomUUID();
        request.setAttribute(REQUEST_ID_ATTRIBUTE, value);
        return value;
    }

    public static UUID currentRequestId() {
        HttpServletRequest request = currentRequest();
        return request == null ? null : ensureRequestId(request);
    }

    public static HttpServletRequest currentRequest() {
        var attrs = RequestContextHolder.getRequestAttributes();
        return attrs instanceof ServletRequestAttributes sra ? sra.getRequest() : null;
    }

    /**
     * Captures only an identity that has already passed JWT signature, account
     * state and authorization-version validation. This survives later security
     * context cleanup while the outer audit filter completes.
     */
    public static void bindVerifiedActor(
            HttpServletRequest request,
            UUID actorId,
            String actorAccount) {
        if (request != null && actorId != null) {
            request.setAttribute(
                    VERIFIED_ACTOR_ATTRIBUTE,
                    new VerifiedActor(actorId, actorAccount));
        }
    }

    public static void bindVerifiedActor(
            HttpServletRequest request,
            UUID actorId,
            String actorAccount,
            UUID sessionId) {
        bindVerifiedActor(request, actorId, actorAccount);
        bindSessionId(request, sessionId);
    }

    public static void bindSessionId(HttpServletRequest request, UUID sessionId) {
        if (request != null && sessionId != null) {
            request.setAttribute(SESSION_ID_ATTRIBUTE, sessionId);
        }
    }

    public static void bindCurrentSessionId(UUID sessionId) {
        bindSessionId(currentRequest(), sessionId);
    }

    public static UUID currentSessionId() {
        return sessionId(currentRequest());
    }

    static UUID sessionId(HttpServletRequest request) {
        Object value = request == null
                ? null
                : request.getAttribute(SESSION_ID_ATTRIBUTE);
        return value instanceof UUID id ? id : null;
    }

    static VerifiedActor verifiedActor(HttpServletRequest request) {
        Object value = request == null
                ? null
                : request.getAttribute(VERIFIED_ACTOR_ATTRIBUTE);
        return value instanceof VerifiedActor actor ? actor : null;
    }

    static boolean shouldAuditOperation(HttpServletRequest request) {
        if (request == null || request.getMethod() == null
                || !AUDITED_METHODS.contains(
                request.getMethod().toUpperCase(Locale.ROOT))) {
            return false;
        }
        String path = request.getRequestURI();
        return path != null && path.startsWith("/api/");
    }

    /**
     * Suppresses only reviewed automatic endpoints after a successful response.
     * Failures are always retained, and ordinary business writes never enter
     * this allowlist.
     */
    static boolean shouldRecordOperation(
            HttpServletRequest request,
            int statusCode,
            boolean requestFailed) {
        if (!shouldAuditOperation(request)) {
            return false;
        }
        if (requestFailed || statusCode >= 400) {
            return true;
        }
        if (Boolean.TRUE.equals(request.getAttribute(
                MEANINGFUL_EVENT_RECORDED_ATTRIBUTE))) {
            return false;
        }
        String method = request.getMethod().toUpperCase(Locale.ROOT);
        String path = normalizedPath(request.getRequestURI());
        if (path.startsWith("/api/admin/audit-logs")) {
            return false;
        }
        if (AuditNoisePolicy.isAutomaticOperation(method, path)) {
            return false;
        }
        return true;
    }

    static void markMeaningfulEventRecorded(HttpServletRequest request) {
        if (request != null) {
            request.setAttribute(MEANINGFUL_EVENT_RECORDED_ATTRIBUTE, Boolean.TRUE);
        }
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

    static String routeGroup(String path) {
        if (path == null || path.isBlank()) {
            return "api";
        }
        String[] segments = path.split("/");
        StringBuilder group = new StringBuilder();
        int added = 0;
        for (String segment : segments) {
            if (segment.isBlank()) {
                continue;
            }
            if (added > 0) {
                group.append('/');
            }
            group.append(segment);
            added++;
            if (added == 3) {
                break;
            }
        }
        return group.isEmpty() ? "api" : group.toString();
    }

    record VerifiedActor(UUID actorId, String actorAccount) {
    }
}
