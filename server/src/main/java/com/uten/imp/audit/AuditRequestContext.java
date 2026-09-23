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
    /**
     * 签名正确、只是已过期的访问令牌(由认证过滤器标记)。它产生的 401 是例行的
     * 「该刷新令牌了」, 不写安全事件; 签名或格式错误的令牌照常记录。
     */
    public static final String EXPIRED_TOKEN_ATTRIBUTE =
            "uten.audit.expiredToken";
    static final String OPERATION_START_NANOS_ATTRIBUTE =
            "uten.audit.operationStartNanos";
    static final String OPERATION_RECORDED_ATTRIBUTE =
            "uten.audit.operationRecorded";
    static final String MEANINGFUL_EVENT_RECORDED_ATTRIBUTE =
            "uten.audit.meaningfulEventRecorded";
    /**
     * 已独立提交(不随业务事务回滚)的失败类显式事件, 例如登录失败; 失败请求不再补通用行。
     * 成功类显式事件(例如导出开始前写的导出记录)不算: 请求随后失败时照样补一条失败记录。
     */
    static final String DURABLE_FAILURE_RECORDED_ATTRIBUTE =
            "uten.audit.durableFailureRecorded";
    private static final Set<String> AUDITED_METHODS =
            Set.of("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD");
    private static final Set<String> READ_METHODS = Set.of("GET", "HEAD");

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
        bindVerifiedActor(request, actorId, actorAccount, (UUID) null, null);
    }

    public static void bindVerifiedActor(
            HttpServletRequest request,
            UUID actorId,
            String actorAccount,
            UUID sessionId) {
        bindVerifiedActor(request, actorId, actorAccount, sessionId, null);
    }

    /**
     * 模拟身份期间真实操作人是发起模拟的管理员, {@code onBehalfOf} 是被模拟的员工账号;
     * 所有请求内的审计事件都记在真实操作人名下并标注被模拟对象(security-12)。
     */
    public static void bindVerifiedActor(
            HttpServletRequest request,
            UUID actorId,
            String actorAccount,
            UUID sessionId,
            UUID onBehalfOf) {
        if (request != null && actorId != null) {
            request.setAttribute(
                    VERIFIED_ACTOR_ATTRIBUTE,
                    new VerifiedActor(actorId, actorAccount, onBehalfOf));
        }
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

    /** 认证过滤器标记: 本次请求带的访问令牌签名正确, 只是过期了。 */
    public static void markExpiredToken(HttpServletRequest request) {
        if (request != null) {
            request.setAttribute(EXPIRED_TOKEN_ATTRIBUTE, Boolean.TRUE);
        }
    }

    static boolean expiredToken(HttpServletRequest request) {
        return request != null
                && Boolean.TRUE.equals(request.getAttribute(EXPIRED_TOKEN_ATTRIBUTE));
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

    static boolean isRead(HttpServletRequest request) {
        return request != null && request.getMethod() != null
                && READ_METHODS.contains(request.getMethod().toUpperCase(Locale.ROOT));
    }

    /**
     * 通用请求行只在三种情况下写: 请求失败(4xx/5xx), 声明了 {@link AuditedRead} 的读取,
     * 以及没进到控制器的写请求。成功的写请求由拦截器写语义业务事件; 已经写过显式业务事件
     * 或安全事件的请求不再重复写。
     */
    static boolean shouldRecordOperation(
            HttpServletRequest request,
            int statusCode,
            boolean requestFailed,
            boolean auditedRead) {
        if (!shouldAuditOperation(request)
                || Boolean.TRUE.equals(request.getAttribute(OPERATION_RECORDED_ATTRIBUTE))) {
            return false;
        }
        if (requestFailed || statusCode >= 400) {
            return !durableFailureRecorded(request);
        }
        if (Boolean.TRUE.equals(request.getAttribute(
                MEANINGFUL_EVENT_RECORDED_ATTRIBUTE))) {
            return false;
        }
        return !isRead(request) || auditedRead;
    }

    static boolean meaningfulEventRecorded(HttpServletRequest request) {
        return request != null && Boolean.TRUE.equals(
                request.getAttribute(MEANINGFUL_EVENT_RECORDED_ATTRIBUTE));
    }

    static boolean durableFailureRecorded(HttpServletRequest request) {
        return request != null && Boolean.TRUE.equals(
                request.getAttribute(DURABLE_FAILURE_RECORDED_ATTRIBUTE));
    }

    /** 独立提交的显式事件; 结果不是 success 时同时算作「这次失败已经有了说明」。 */
    static void markDurableEventRecorded(HttpServletRequest request, boolean failure) {
        if (request != null) {
            request.setAttribute(MEANINGFUL_EVENT_RECORDED_ATTRIBUTE, Boolean.TRUE);
            if (failure) {
                request.setAttribute(DURABLE_FAILURE_RECORDED_ATTRIBUTE, Boolean.TRUE);
            }
        }
    }

    static void markMeaningfulEventRecorded(HttpServletRequest request) {
        if (request != null) {
            request.setAttribute(MEANINGFUL_EVENT_RECORDED_ATTRIBUTE, Boolean.TRUE);
        }
    }

    static void markOperationRecorded(HttpServletRequest request) {
        if (request != null) {
            request.setAttribute(OPERATION_RECORDED_ATTRIBUTE, Boolean.TRUE);
        }
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

    record VerifiedActor(UUID actorId, String actorAccount, UUID onBehalfOf) {
    }
}
