package com.uten.imp.audit;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;
import java.util.Locale;

/**
 * 显式审计写入（登录/改密/重置密码等非数据变更事件）。
 * 用 Propagation.REQUIRES_NEW 确保审计即便主流程回滚也落库（如登录失败）。
 * 数据变更类审计由 DB 触发器负责。
 */
@Service
public class AuditService {

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
        AuditLog a = base(
                truncate(action, 120),
                truncate(targetType, 200),
                truncate(targetId, 1000),
                truncate(result, 500));
        a.setActorId(actorId);
        a.setActorAccount(truncate(actorAccount, 200));
        a.setEventSource("business");
        fillRequest(a);
        repo.save(a);
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
}
