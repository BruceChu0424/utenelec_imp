package com.uten.imp.audit;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;
import org.springframework.web.servlet.HandlerInterceptor;

import java.util.Locale;
import java.util.concurrent.TimeUnit;

/**
 * Records API operations that reach Spring MVC. {@link AuditRequestContextFilter}
 * fills the requests rejected earlier in the filter/dispatcher chain.
 *
 * <p>This is the coverage layer for user actions. Table audit triggers remain
 * responsible for before/after values on high-value entities. Request bodies
 * are deliberately excluded to avoid copying credentials or PII into logs.
 */
@Slf4j
@Component
public class UserOperationAuditInterceptor implements HandlerInterceptor {

    private final SecurityContextCurrentUser currentUser;
    private final AuditService auditService;

    public UserOperationAuditInterceptor(
            SecurityContextCurrentUser currentUser,
            AuditService auditService) {
        this.currentUser = currentUser;
        this.auditService = auditService;
    }

    @Override
    public boolean preHandle(
            HttpServletRequest request,
            HttpServletResponse response,
            Object handler) {
        AuditRequestContext.ensureRequestId(request);
        if (AuditRequestContext.shouldAuditOperation(request)
                && !(request.getAttribute(
                        AuditRequestContext.OPERATION_START_NANOS_ATTRIBUTE) instanceof Long)) {
            request.setAttribute(
                    AuditRequestContext.OPERATION_START_NANOS_ATTRIBUTE,
                    System.nanoTime());
        }
        return true;
    }

    @Override
    public void afterCompletion(
            HttpServletRequest request,
            HttpServletResponse response,
            Object handler,
            Exception exception) {
        Object started = request.getAttribute(
                AuditRequestContext.OPERATION_START_NANOS_ATTRIBUTE);
        if (!(started instanceof Long startNanos)) {
            return;
        }
        logSafely(
                request,
                response,
                currentUser.get().orElse(null),
                startNanos,
                exception != null);
    }

    private void logSafely(
            HttpServletRequest request,
            HttpServletResponse response,
            AuthUser user,
            long startNanos,
            boolean requestFailed) {
        int status = response.getStatus();
        if (requestFailed && status < 400) {
            status = HttpServletResponse.SC_INTERNAL_SERVER_ERROR;
        }
        if (!AuditRequestContext.shouldRecordOperation(
                request, status, requestFailed)) {
            request.setAttribute(
                    AuditRequestContext.OPERATION_RECORDED_ATTRIBUTE,
                    Boolean.TRUE);
            return;
        }
        long durationMillis = Math.max(
                0,
                TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startNanos));
        String method = request.getMethod().toUpperCase(Locale.ROOT);
        String path = request.getRequestURI();
        try {
            auditService.logHttpOperation(
                    user == null ? null : user.getId(),
                    user == null ? null : user.getLoginAccount(),
                    method,
                    path,
                    AuditRequestContext.routeGroup(path),
                    status,
                    durationMillis);
            request.setAttribute(
                    AuditRequestContext.OPERATION_RECORDED_ATTRIBUTE,
                    Boolean.TRUE);
        } catch (RuntimeException auditFailure) {
            // The response has already been produced; an audit sink outage must
            // be observable, but must not corrupt the completed business reply.
            log.error("Failed to persist user-operation audit metadata", auditFailure);
        }
    }

}
