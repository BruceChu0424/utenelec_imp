package com.uten.imp.audit;

import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.util.UUID;
import java.util.Locale;
import java.util.concurrent.TimeUnit;

/**
 * Establishes audit correlation before authentication so even a filter-level
 * 401 response can be matched to a local client receipt.
 */
@Component
@RequiredArgsConstructor
@Slf4j
public class AuditRequestContextFilter extends OncePerRequestFilter {

    private final AuditDeviceContext deviceContext;
    private final SecurityContextCurrentUser currentUser;
    private final AuditService auditService;

    @Override
    protected void doFilterInternal(
            HttpServletRequest request,
            HttpServletResponse response,
            FilterChain filterChain) throws ServletException, IOException {
        UUID requestId = AuditRequestContext.ensureRequestId(request);
        AuditDeviceEvidence evidence = deviceContext.ensure(request);
        response.setHeader(
                AuditRequestContext.RESPONSE_REQUEST_ID_HEADER,
                requestId.toString());
        if (evidence.clientEventId() != null) {
            response.setHeader(
                    AuditDeviceContext.HEADER_CLIENT_EVENT_ID,
                    evidence.clientEventId().toString());
        }
        boolean auditOperation = AuditRequestContext.shouldAuditOperation(request);
        if (auditOperation) {
            request.setAttribute(
                    AuditRequestContext.OPERATION_START_NANOS_ATTRIBUTE,
                    System.nanoTime());
        }
        boolean chainFailed = false;
        try {
            filterChain.doFilter(request, response);
        } catch (IOException | ServletException | RuntimeException exception) {
            chainFailed = true;
            throw exception;
        } finally {
            if (auditOperation
                    && !Boolean.TRUE.equals(request.getAttribute(
                            AuditRequestContext.OPERATION_RECORDED_ATTRIBUTE))) {
                logFallback(request, response, chainFailed);
            }
        }
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        String path = request.getRequestURI();
        return path == null || !path.startsWith("/api/");
    }

    private void logFallback(
            HttpServletRequest request,
            HttpServletResponse response,
            boolean chainFailed) {
        Object started = request.getAttribute(
                AuditRequestContext.OPERATION_START_NANOS_ATTRIBUTE);
        long startNanos = started instanceof Long value ? value : System.nanoTime();
        long durationMillis = Math.max(
                0,
                TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startNanos));
        int status = response.getStatus();
        if (chainFailed && status < 400) {
            status = HttpServletResponse.SC_INTERNAL_SERVER_ERROR;
        }
        if (!AuditRequestContext.shouldRecordOperation(
                request, status, chainFailed)) {
            request.setAttribute(
                    AuditRequestContext.OPERATION_RECORDED_ATTRIBUTE,
                    Boolean.TRUE);
            return;
        }
        String method = request.getMethod().toUpperCase(Locale.ROOT);
        String path = request.getRequestURI();
        try {
            AuditRequestContext.VerifiedActor verifiedActor =
                    AuditRequestContext.verifiedActor(request);
            var user = verifiedActor == null
                    ? currentUser.get().orElse(null)
                    : null;
            auditService.logHttpOperation(
                    verifiedActor == null
                            ? user == null ? null : user.getId()
                            : verifiedActor.actorId(),
                    verifiedActor == null
                            ? user == null ? null : user.getLoginAccount()
                            : verifiedActor.actorAccount(),
                    method,
                    path,
                    AuditRequestContext.routeGroup(path),
                    status,
                    durationMillis);
            request.setAttribute(
                    AuditRequestContext.OPERATION_RECORDED_ATTRIBUTE,
                    Boolean.TRUE);
        } catch (RuntimeException auditFailure) {
            log.error("Failed to persist fallback operation audit metadata", auditFailure);
        }
    }
}
