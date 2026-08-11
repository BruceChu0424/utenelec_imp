package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiError;
import com.uten.imp.common.web.ErrorCode;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

/**
 * Restricts every local-site API endpoint, including login, to configured source CIDRs.
 *
 * <p>{@link HttpServletRequest#getRemoteAddr()} is intentionally the only address used.
 * Tomcat's RemoteIpValve may replace it, but only after the connector has verified the
 * immediate peer against {@code server.tomcat.remoteip.internal-proxies}. This filter
 * never trusts a caller-supplied Forwarded/X-Forwarded-For header directly.
 */
@Component
@RequiredArgsConstructor
public class LocalNetworkGuardFilter extends OncePerRequestFilter {

    private static final String DENIED_MESSAGE = "当前网络不在公司局域网允许范围内";

    private final ObjectMapper objectMapper;
    private final AuditService auditService;
    private final LocalNetworkAccessPolicy networkPolicy;

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain chain)
            throws ServletException, IOException {
        if (networkPolicy.isAllowed(request.getRemoteAddr())) {
            chain.doFilter(request, response);
            return;
        }
        try {
            auditService.logSecurityEvent(
                    request, null, null,
                    "local_network_access_denied", "forbidden", 403);
        } catch (RuntimeException ignored) {
            // The network boundary remains fail-closed if the audit sink is unavailable.
        }
        response.setStatus(HttpServletResponse.SC_FORBIDDEN);
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.setCharacterEncoding(StandardCharsets.UTF_8.name());
        response.getWriter().write(objectMapper.writeValueAsString(
                ApiError.of(ErrorCode.FORBIDDEN, DENIED_MESSAGE)));
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        String path = request.getRequestURI();
        String contextPath = request.getContextPath();
        if (contextPath != null && !contextPath.isEmpty() && path.startsWith(contextPath)) {
            path = path.substring(contextPath.length());
        }
        // Actuator stays outside the /api boundary for local health monitoring.
        return !(path.equals("/api") || path.startsWith("/api/"));
    }
}
