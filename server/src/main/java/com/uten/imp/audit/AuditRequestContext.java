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
    static final String OPERATION_START_NANOS_ATTRIBUTE =
            "uten.audit.operationStartNanos";
    static final String OPERATION_RECORDED_ATTRIBUTE =
            "uten.audit.operationRecorded";
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
