package com.uten.imp.audit;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.json.JsonMapper;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

/**
 * 显式审计写入（登录/改密/重置密码等非数据变更事件）。
 * 用 Propagation.REQUIRES_NEW 确保审计即便主流程回滚也落库（如登录失败）。
 * 数据变更类审计由 DB 触发器负责。
 */
@Service
public class AuditService {

    private static final JsonMapper AUDIT_JSON = JsonMapper.builder().build();

    private final AuditLogRepository repo;
    private final AuditDeviceContext deviceContext;

    public AuditService(AuditLogRepository repo, AuditDeviceContext deviceContext) {
        this.repo = repo;
        this.deviceContext = deviceContext;
    }

    /** 显式指定操作人（登录/改密/logout 等场景；actor 由调用方给出）。 */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void logExplicit(UUID actorId, String actorAccount, String action,
                            String targetType, String targetId, String result) {
        persistBusinessEvent(
                actorId, actorAccount, action, targetType, targetId, result, null);
    }

    /** Explicit authentication evidence with a server-authoritative session UUID. */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void logExplicit(UUID actorId, String actorAccount, String action,
                            String targetType, String targetId, String result,
                            UUID sessionId) {
        persistBusinessEvent(
                actorId, actorAccount, action, targetType, targetId, result, sessionId);
    }

    private void persistBusinessEvent(
            UUID actorId,
            String actorAccount,
            String action,
            String targetType,
            String targetId,
            String result,
            UUID sessionId) {
        AuditLog a = base(
                truncate(action, 120),
                truncate(targetType, 200),
                truncate(targetId, 1000),
                truncate(result, 500));
        a.setActorId(actorId);
        a.setActorAccount(truncate(actorAccount, 200));
        a.setEventSource("business");
        fillRequest(a, currentRequest(), sessionId);
        repo.save(a);
        AuditRequestContext.markMeaningfulEventRecorded(currentRequest());
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
                actorId, actorAccount, action, targetType, targetId, result, null);
    }

    /** Transaction-bound success evidence with an explicit authentication session. */
    @Transactional(propagation = Propagation.MANDATORY)
    public void logCommitted(UUID actorId, String actorAccount, String action,
                             String targetType, String targetId, String result,
                             UUID sessionId) {
        persistBusinessEvent(
                actorId, actorAccount, action, targetType, targetId, result, sessionId);
    }

    /**
     * Fail-closed evidence that one detail object passed existence and
     * object-scope checks and was resolved for the response. It does not claim
     * that JSON conversion or client network delivery completed.
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
        persistReadableView(
                actorId,
                actorAccount,
                action,
                targetType,
                targetId == null ? null : targetId.toString(),
                "business_detail_view",
                null,
                targetDisplayName,
                targetBusinessCode,
                targetLegacyCode);
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
        value.setActorId(actorId);
        value.setActorAccount(truncate(actorAccount, 200));
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
        fillRequest(value, request);
        repo.save(value);
        AuditRequestContext.markMeaningfulEventRecorded(request);
    }

    /** One readable coverage row for every user-facing API request. */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void logHttpOperation(UUID actorId,
                                 String actorAccount,
                                 String method,
                                 String path,
                                 String routeGroup,
                                 int statusCode,
                                 long durationMillis) {
        String normalizedMethod = method == null ? "unknown" : method.toLowerCase(Locale.ROOT);
        AuditLog a = base(
                "http_" + normalizedMethod,
                truncate(routeGroup, 200),
                truncate(path, 1000),
                statusCode < 400 ? "success" : "failure");
        a.setActorId(actorId);
        a.setActorAccount(truncate(actorAccount, 200));
        a.setEventSource("request");
        a.setHttpMethod(truncate(method, 10));
        a.setHttpPath(truncate(path, 1000));
        a.setStatusCode(statusCode);
        a.setDurationMs(Math.max(0, durationMillis));
        fillRequest(a);
        repo.save(a);
    }

    /** Security-filter event that can occur before a controller is entered. */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void logSecurityEvent(HttpServletRequest request,
                                 UUID actorId,
                                 String actorAccount,
                                 String action,
                                 String result,
                                 int statusCode) {
        String path = request == null ? null : request.getRequestURI();
        AuditLog a = base(action, "api_request", path, result);
        a.setActorId(actorId);
        a.setActorAccount(truncate(actorAccount, 200));
        a.setEventSource("security");
        a.setStatusCode(statusCode);
        if (request != null) {
            a.setHttpMethod(truncate(request.getMethod(), 10));
            a.setHttpPath(truncate(path, 1000));
        }
        fillRequest(a, request);
        repo.save(a);
    }

    private AuditLog base(String action, String targetType, String targetId, String result) {
        AuditLog a = new AuditLog();
        a.setAction(action);
        a.setTargetType(targetType);
        a.setTargetId(targetId);
        a.setResult(result);
        return a;
    }

    private void fillRequest(AuditLog a) {
        fillRequest(a, currentRequest());
    }

    private void fillRequest(AuditLog a, HttpServletRequest req) {
        fillRequest(a, req, null);
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
