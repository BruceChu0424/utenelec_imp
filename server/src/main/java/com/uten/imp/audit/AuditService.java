package com.uten.imp.audit;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.json.JsonMapper;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.time.Clock;
import java.time.Duration;
import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

/**
 * Java 侧审计写入的唯一入口(登录/改密/显式业务事件/语义写事件/请求行/安全事件)。
 *
 * <p>每一行在落库前统一做三件事(ADR-105):
 * <ul>
 *   <li>操作人: 请求内一律取已通过认证的真实操作人; 模拟身份期间记在发起模拟的管理员名下,
 *       并在 {@code on_behalf_of} 标注被模拟的账号, 调用方传入的操作人只用于认证前的登录类事件;</li>
 *   <li>账号: 只存脱敏展示值(保留后 4 位), 未认证的输入不像号码时不落库;</li>
 *   <li>分类: 由 {@link AuditClassifier} 一次算好风险等级与事件类型, 存进表里。</li>
 * </ul>
 * 数据变更由数据库行级审计按三清单负责。
 */
@Service
public class AuditService {

    private static final JsonMapper AUDIT_JSON = JsonMapper.builder().build();
    /** 同一人在同一会话里重复打开同一对象的详情, 30 分钟内只记一次查看。 */
    static final Duration DETAIL_VIEW_DEDUPE_WINDOW = Duration.ofMinutes(30);

    private final AuditLogRepository repo;
    private final AuditDeviceContext deviceContext;
    private final Clock clock;
    private final AuditEventThrottle denialThrottle;

    @Autowired
    public AuditService(AuditLogRepository repo, AuditDeviceContext deviceContext) {
        this(repo, deviceContext, Clock.systemUTC());
    }

    AuditService(AuditLogRepository repo, AuditDeviceContext deviceContext, Clock clock) {
        this.repo = repo;
        this.deviceContext = deviceContext;
        this.clock = clock;
        this.denialThrottle = new AuditEventThrottle(clock);
    }

    /** 显式指定操作人(登录/改密/logout 等认证前或认证链上的场景)。 */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void logExplicit(UUID actorId, String actorAccount, String action,
                            String targetType, String targetId, String result) {
        persistBusinessEvent(
                actorId, actorAccount, action, targetType, targetId, result, null, true);
    }

    /** Explicit authentication evidence with a server-authoritative session UUID. */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void logExplicit(UUID actorId, String actorAccount, String action,
                            String targetType, String targetId, String result,
                            UUID sessionId) {
        persistBusinessEvent(
                actorId, actorAccount, action, targetType, targetId, result, sessionId, true);
    }

    /**
     * Writes a success event inside the caller's business transaction. Use for
     * state-changing actions whose audit event must disappear if the business
     * transaction rolls back.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void logCommitted(UUID actorId, String actorAccount, String action,
                             String targetType, String targetId, String result) {
        persistBusinessEvent(
                actorId, actorAccount, action, targetType, targetId, result, null, false);
    }

    /** Transaction-bound success evidence with an explicit authentication session. */
    @Transactional(propagation = Propagation.MANDATORY)
    public void logCommitted(UUID actorId, String actorAccount, String action,
                             String targetType, String targetId, String result,
                             UUID sessionId) {
        persistBusinessEvent(
                actorId, actorAccount, action, targetType, targetId, result, sessionId, false);
    }

    private void persistBusinessEvent(
            UUID actorId,
            String actorAccount,
            String action,
            String targetType,
            String targetId,
            String result,
            UUID sessionId,
            boolean durable) {
        HttpServletRequest request = currentRequest();
        AuditLog a = base(
                truncate(action, 120),
                truncate(targetType, 200),
                truncate(targetId, 1000),
                truncate(result, 500));
        a.setEventSource("business");
        applyActor(a, request, actorId, actorAccount);
        fillRequest(a, request, sessionId);
        save(a);
        if (durable) {
            AuditRequestContext.markDurableEventRecorded(request, AuditClassifier.failed(result, null));
        } else {
            AuditRequestContext.markMeaningfulEventRecorded(request);
        }
    }

    /**
     * Fail-closed evidence that one detail object passed existence and
     * object-scope checks and was resolved for the response. It does not claim
     * that JSON conversion or client network delivery completed.
     *
     * <p>同一操作人在同一会话里 30 分钟内重复查看同一对象(含页面静默刷新)只记第一次。
     */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void logSuccessfulDetailView(
            UUID actorId,
            String actorAccount,
            String action,
            String targetType,
            UUID targetId,
            String targetDisplayName,
            String targetBusinessCode,
            String targetLegacyCode) {
        HttpServletRequest request = currentRequest();
        AuditRequestContext.VerifiedActor verified = AuditRequestContext.verifiedActor(request);
        UUID effectiveActor = verified == null ? actorId : verified.actorId();
        String safeAction = truncate(action, 120);
        String safeTargetType = truncate(targetType, 200);
        String safeTargetId = targetId == null ? null : targetId.toString();
        UUID sessionId = AuditRequestContext.sessionId(request);
        if (effectiveActor != null && safeTargetId != null
                && recentlyViewed(effectiveActor, safeAction, safeTargetType, safeTargetId, sessionId)) {
            AuditRequestContext.markMeaningfulEventRecorded(request);
            return;
        }
        persistReadableView(
                actorId,
                actorAccount,
                safeAction,
                safeTargetType,
                safeTargetId,
                "business_detail_view",
                null,
                targetDisplayName,
                targetBusinessCode,
                targetLegacyCode);
    }

    private boolean recentlyViewed(
            UUID actorId, String action, String targetType, String targetId, UUID sessionId) {
        OffsetDateTime since = OffsetDateTime.now(clock).minus(DETAIL_VIEW_DEDUPE_WINDOW);
        return sessionId == null
                ? repo.existsByActorIdAndActionAndTargetTypeAndTargetIdAndSessionIdIsNullAndCreatedAtAfter(
                        actorId, action, targetType, targetId, since)
                : repo.existsByActorIdAndActionAndTargetTypeAndTargetIdAndSessionIdAndCreatedAtAfter(
                        actorId, action, targetType, targetId, sessionId, since);
    }

    /**
     * Records a successful read of sensitive audit evidence with a concise,
     * Chinese display reference for the session timeline. The exact machine
     * scope remains in {@code targetId}; the display metadata never replaces
     * the canonical session/user/audit identifiers.
     */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void logSuccessfulAuditView(
            UUID actorId,
            String actorAccount,
            String action,
            String targetType,
            String targetId,
            String viewDisplayName) {
        persistReadableView(
                actorId,
                actorAccount,
                action,
                targetType,
                targetId,
                "audit_evidence_view",
                viewDisplayName,
                null,
                null,
                null);
    }

    private void persistReadableView(
            UUID actorId,
            String actorAccount,
            String action,
            String targetType,
            String targetId,
            String metadataKind,
            String legacyViewDisplayName,
            String targetDisplayName,
            String targetBusinessCode,
            String targetLegacyCode) {
        AuditLog value = base(
                truncate(action, 120),
                truncate(targetType, 200),
                truncate(targetId, 1000),
                "success");
        value.setEventSource("business");
        Map<String, Object> metadata = new LinkedHashMap<>();
        metadata.put("view_metadata_kind", metadataKind);
        if ("audit_evidence_view".equals(metadataKind)) {
            metadata.put("view_display_name", truncate(legacyViewDisplayName, 200));
        } else {
            metadata.put("target_display_name",
                    truncate(blankToNull(targetDisplayName), 200));
            metadata.put("target_business_code",
                    truncate(blankToNull(targetBusinessCode), 200));
            metadata.put("target_legacy_code",
                    truncate(blankToNull(targetLegacyCode), 100));
        }
        try {
            value.setAfter(AUDIT_JSON.writeValueAsString(metadata));
        } catch (JsonProcessingException exception) {
            throw new IllegalStateException("Unable to encode view audit metadata", exception);
        }
        HttpServletRequest request = currentRequest();
        applyActor(value, request, actorId, actorAccount);
        fillRequest(value, request, null);
        save(value);
        AuditRequestContext.markMeaningfulEventRecorded(request);
    }

    /**
     * 一个成功(或失败)写请求的语义业务事件: 动作码是「资源.方法」, 目标取路径里的对象编号。
     * 取代通用的 http_post/http_put 请求行。
     */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void logSemanticOperation(UUID actorId,
                                     String actorAccount,
                                     String action,
                                     String targetType,
                                     String targetId,
                                     String method,
                                     String path,
                                     int statusCode,
                                     long durationMillis) {
        HttpServletRequest request = currentRequest();
        if (statusCode >= 400 && !admitAnonymousFailure(request, actorId, action, statusCode)) {
            return;
        }
        AuditLog a = base(
                truncate(action, 120),
                truncate(targetType, 200),
                truncate(targetId, 1000),
                statusCode < 400 ? "success" : "failure");
        a.setEventSource("business");
        a.setHttpMethod(truncate(method, 10));
        a.setHttpPath(truncate(path, 1000));
        a.setStatusCode(statusCode);
        a.setDurationMs(Math.max(0, durationMillis));
        applyActor(a, request, actorId, actorAccount);
        fillRequest(a, request, null);
        save(a);
    }

    /** 通用请求行: 失败的请求、声明了需要追溯的读取、没进到控制器的写请求。 */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void logHttpOperation(UUID actorId,
                                 String actorAccount,
                                 String method,
                                 String path,
                                 String routeGroup,
                                 int statusCode,
                                 long durationMillis) {
        HttpServletRequest request = currentRequest();
        String normalizedMethod = method == null ? "unknown" : method.toLowerCase(Locale.ROOT);
        if (statusCode >= 400
                && !admitAnonymousFailure(request, actorId, "http_" + normalizedMethod, statusCode)) {
            return;
        }
        AuditLog a = base(
                "http_" + normalizedMethod,
                truncate(routeGroup, 200),
                truncate(path, 1000),
                statusCode < 400 ? "success" : "failure");
        a.setEventSource("request");
        a.setHttpMethod(truncate(method, 10));
        a.setHttpPath(truncate(path, 1000));
        a.setStatusCode(statusCode);
        a.setDurationMs(Math.max(0, durationMillis));
        applyActor(a, request, actorId, actorAccount);
        fillRequest(a, request, null);
        save(a);
    }

    /**
     * Security-filter event that can occur before a controller is entered.
     *
     * <p>写过安全事件的请求不再写通用请求行; 签名正确只是过期的令牌产生的 401 不记;
     * 其余按 {@link AuditEventThrottle} 节流: 已登录会话同一路径每分钟一条, 匿名来源按
     * 「IP + 动作 + 状态码」每分钟一条, 并受来源与全局每分钟上限约束。
     */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void logSecurityEvent(HttpServletRequest request,
                                 UUID actorId,
                                 String actorAccount,
                                 String action,
                                 String result,
                                 int statusCode) {
        AuditRequestContext.markOperationRecorded(request);
        if ("access_denied".equals(action) && statusCode == 401
                && AuditRequestContext.expiredToken(request)) {
            return;
        }
        String path = request == null ? null : request.getRequestURI();
        if (!admitThrottled(request, actorId, action + '|' + result, statusCode)) {
            return;
        }
        AuditLog a = base(action, "api_request", path, result);
        a.setEventSource("security");
        a.setStatusCode(statusCode);
        if (request != null) {
            a.setHttpMethod(truncate(request.getMethod(), 10));
            a.setHttpPath(truncate(path, 1000));
        }
        applyActor(a, request, actorId, actorAccount);
        fillRequest(a, request, null);
        save(a);
    }

    /** 匿名(没有会话也没有已验证操作人)的失败请求行同样节流; 已登录用户的失败照常逐条记录。 */
    private boolean admitAnonymousFailure(
            HttpServletRequest request, UUID actorId, String kind, int statusCode) {
        return !isAnonymous(request, actorId) || admitThrottled(request, actorId, kind, statusCode);
    }

    private boolean admitThrottled(HttpServletRequest request, UUID actorId, String kind, int statusCode) {
        UUID sessionId = AuditRequestContext.sessionId(request);
        UUID actor = effectiveActorId(request, actorId);
        boolean anonymous = sessionId == null && actor == null;
        String origin = sessionId != null ? "s:" + sessionId
                : actor != null ? "u:" + actor
                : "ip:" + (request == null ? "" : request.getRemoteAddr());
        // 匿名来源的键不含路径: 换路径换不出新键(security-11)。
        String key = origin + '|' + kind + '|' + statusCode
                + (anonymous ? "" : "|" + (request == null ? "" : request.getRequestURI()));
        return denialThrottle.admit(origin, anonymous, key);
    }

    private static boolean isAnonymous(HttpServletRequest request, UUID actorId) {
        return AuditRequestContext.sessionId(request) == null && effectiveActorId(request, actorId) == null;
    }

    private static UUID effectiveActorId(HttpServletRequest request, UUID actorId) {
        AuditRequestContext.VerifiedActor verified = AuditRequestContext.verifiedActor(request);
        return verified == null ? actorId : verified.actorId();
    }

    private void applyActor(AuditLog a, HttpServletRequest request, UUID actorId, String actorAccount) {
        AuditRequestContext.VerifiedActor verified = AuditRequestContext.verifiedActor(request);
        if (verified != null) {
            a.setActorId(verified.actorId());
            a.setActorAccount(truncate(AuditAccountMask.forStorage(true, verified.actorAccount()), 200));
            a.setOnBehalfOf(verified.onBehalfOf());
            return;
        }
        a.setActorId(actorId);
        a.setActorAccount(truncate(AuditAccountMask.forStorage(actorId != null, actorAccount), 200));
    }

    private void save(AuditLog a) {
        AuditClassifier.Classification classification = AuditClassifier.classify(
                a.getEventSource(), a.getAction(), a.getTargetType(), a.getHttpPath(),
                a.getResult(), a.getStatusCode());
        a.setRiskLevel(classification.riskLevel());
        a.setEventCategory(classification.eventCategory());
        repo.save(a);
    }

    private AuditLog base(String action, String targetType, String targetId, String result) {
        AuditLog a = new AuditLog();
        a.setAction(action);
        a.setTargetType(targetType);
        a.setTargetId(targetId);
        a.setResult(result);
        a.setCreatedAt(OffsetDateTime.now(clock));
        return a;
    }

    private void fillRequest(
            AuditLog a,
            HttpServletRequest req,
            UUID explicitSessionId) {
        UUID sessionId = explicitSessionId != null
                ? explicitSessionId
                : AuditRequestContext.sessionId(req);
        a.setSessionId(sessionId);
        if (req != null) {
            a.setIp(truncate(req.getRemoteAddr(), 64));
            a.setUserAgent(truncate(req.getHeader("User-Agent"), 1000));
            a.setRequestId(AuditRequestContext.ensureRequestId(req));
            deviceContext.ensure(req).applyTo(a);
            if (a.getHttpMethod() == null) {
                a.setHttpMethod(truncate(req.getMethod(), 10));
            }
            if (a.getHttpPath() == null) {
                a.setHttpPath(truncate(req.getRequestURI(), 1000));
            }
        }
    }

    private HttpServletRequest currentRequest() {
        return AuditRequestContext.currentRequest();
    }

    private String truncate(String value, int maxLength) {
        if (value == null || value.length() <= maxLength) {
            return value;
        }
        return value.substring(0, maxLength);
    }

    private String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }
}
