package com.uten.imp.audit;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;
import org.springframework.web.servlet.HandlerInterceptor;

import java.util.Locale;
import java.util.Set;
import java.util.concurrent.TimeUnit;

/**
 * Records every authenticated state-changing HTTP operation.
 *
 * <p>This is the coverage layer for user actions. Table audit triggers remain
 * responsible for before/after values on high-value entities. Request bodies
 * are deliberately excluded to avoid copying credentials or PII into logs.
 */
@Slf4j
@Component
public class UserOperationAuditInterceptor implements HandlerInterceptor {

    private static final String START_NANOS_ATTRIBUTE =
            UserOperationAuditInterceptor.class.getName() + ".startNanos";
    private static final Set<String> MUTATING_METHODS =
            Set.of("POST", "PUT", "PATCH", "DELETE");

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
        if (shouldAudit(request)) {
            request.setAttribute(START_NANOS_ATTRIBUTE, System.nanoTime());
        }
        return true;
    }

    @Override
    public void afterCompletion(
            HttpServletRequest request,
            HttpServletResponse response,
            Object handler,
            Exception exception) {
        Object started = request.getAttribute(START_NANOS_ATTRIBUTE);
        if (!(started instanceof Long startNanos)) {
            return;
        }
        currentUser.get().ifPresent(user -> logSafely(request, response, user, startNanos));
    }

    private boolean shouldAudit(HttpServletRequest request) {
        return MUTATING_METHODS.contains(request.getMethod().toUpperCase(Locale.ROOT));
    }

    private void logSafely(
            HttpServletRequest request,
            HttpServletResponse response,
            AuthUser user,
            long startNanos) {
        int status = response.getStatus();
        long durationMillis = Math.max(
                0,
                TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startNanos));
        String outcome = status < 400 ? "success" : "failure";
        String method = request.getMethod().toUpperCase(Locale.ROOT);
        String path = request.getRequestURI();
        try {
            auditService.logExplicit(
                    user.getId(),
                    user.getLoginAccount(),
                    "http_" + method.toLowerCase(Locale.ROOT),
                    routeGroup(path),
                    path,
                    outcome + ':' + status + ':' + durationMillis + "ms");
        } catch (RuntimeException auditFailure) {
            // The response has already been produced; an audit sink outage must
            // be observable, but must not corrupt the completed business reply.
            log.error("Failed to persist user-operation audit metadata", auditFailure);
        }
    }

    private String routeGroup(String path) {
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
}
