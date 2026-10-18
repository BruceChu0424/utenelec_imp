package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiError;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.AuthSessionService;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.http.MediaType;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.time.Clock;

/** Remote requests require the live session's MFA proof; never infer it from token/header/device names. */
@Component
@RequiredArgsConstructor
public class RemoteMfaGuardFilter extends OncePerRequestFilter {
    private final ObjectMapper mapper;
    private final AuditService audit;
    private final RemoteAccessPolicy access;
    private final Clock clock;

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        var authentication = SecurityContextHolder.getContext().getAuthentication();
        if (!access.isRemoteRequest() || authentication == null || !authentication.isAuthenticated()
                || !(authentication.getPrincipal() instanceof AuthUser user) || user.isVisitor()) {
            chain.doFilter(request, response); return;
        }
        String path = SecurityRequestPath.withinApplication(request);
        boolean recovery = ("GET".equals(request.getMethod()) && "/api/auth/mfa".equals(path))
                || ("POST".equals(request.getMethod()) && "/api/auth/mfa/verify".equals(path))
                || ("POST".equals(request.getMethod()) && "/api/auth/logout".equals(path));
        if (user.getImpersonatedBy() == null && (recovery || AuthSessionService.isMfaVerified(user.getMfaVerifiedAt(), clock.instant()))) {
            chain.doFilter(request, response); return;
        }
        ErrorCode error = user.getImpersonatedBy() == null ? ErrorCode.MFA_REQUIRED : ErrorCode.FORBIDDEN;
        try { audit.logSecurityEvent(request, user.getId(), user.getLoginAccount(), "remote_mfa_required", "forbidden", error.getHttpStatus()); }
        catch (RuntimeException ignored) { /* auditing must not open the boundary */ }
        response.setStatus(error.getHttpStatus());
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.setCharacterEncoding(StandardCharsets.UTF_8.name());
        response.getWriter().write(mapper.writeValueAsString(ApiError.of(error, null)));
    }

    @Override protected boolean shouldNotFilter(HttpServletRequest request) {
        return !SecurityRequestPath.isApi(SecurityRequestPath.withinApplication(request));
    }
}
