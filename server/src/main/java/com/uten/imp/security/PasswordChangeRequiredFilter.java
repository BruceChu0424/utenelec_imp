package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiError;
import com.uten.imp.common.web.ErrorCode;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.MediaType;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Set;

/**
 * Keeps a staff account confined to the password-change flow while its
 * authoritative account state still requires a first-login password change.
 */
@Slf4j
public final class PasswordChangeRequiredFilter extends OncePerRequestFilter {

    private static final Set<AllowedRequest> ALLOWLIST = Set.of(
            new AllowedRequest("POST", "/api/auth/change-password"),
            new AllowedRequest("POST", "/api/auth/logout"),
            new AllowedRequest("GET", "/api/auth/me"));

    private final ObjectMapper objectMapper;
    private final AuditService auditService;

    public PasswordChangeRequiredFilter(ObjectMapper objectMapper, AuditService auditService) {
        this.objectMapper = objectMapper;
        this.auditService = auditService;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain chain)
            throws ServletException, IOException {
        Authentication authentication = SecurityContextHolder.getContext().getAuthentication();
        if (authentication == null
                || !authentication.isAuthenticated()
                || !(authentication.getPrincipal() instanceof AuthUser user)
                || !user.isMustChangePassword()
                || isAllowed(request)) {
            chain.doFilter(request, response);
            return;
        }

        deny(request, response, user);
    }

    private void deny(HttpServletRequest request,
                      HttpServletResponse response,
                      AuthUser user) throws IOException {
        try {
            auditService.logSecurityEvent(
                    request,
                    user.getImpersonatedBy() == null ? user.getId() : user.getImpersonatedBy(),
                    user.getImpersonatedBy() == null ? user.getLoginAccount() : null,
                    "password_change_required",
                    "forbidden",
                    ErrorCode.PASSWORD_CHANGE_REQUIRED.getHttpStatus());
        } catch (RuntimeException auditFailure) {
            log.error("Failed to persist password-change-required audit event", auditFailure);
        }

        response.setStatus(ErrorCode.PASSWORD_CHANGE_REQUIRED.getHttpStatus());
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.setCharacterEncoding(StandardCharsets.UTF_8.name());
        response.getWriter().write(objectMapper.writeValueAsString(
                ApiError.of(ErrorCode.PASSWORD_CHANGE_REQUIRED, null)));
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        String path = pathWithinApplication(request);
        return !(path.equals("/api") || path.startsWith("/api/"));
    }

    private static boolean isAllowed(HttpServletRequest request) {
        return ALLOWLIST.contains(new AllowedRequest(
                request.getMethod(), pathWithinApplication(request)));
    }

    private static String pathWithinApplication(HttpServletRequest request) {
        String path = request.getRequestURI();
        String contextPath = request.getContextPath();
        if (contextPath != null && !contextPath.isEmpty() && path.startsWith(contextPath)) {
            return path.substring(contextPath.length());
        }
        return path;
    }

    private record AllowedRequest(String method, String path) {
    }
}
