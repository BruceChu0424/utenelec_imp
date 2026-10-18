package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiError;
import com.uten.imp.common.web.ErrorCode;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

/**
 * Classifies every API request, including login, before authentication.
 *
 * <p>The office connector uses the configured numeric source CIDRs. The loopback-only
 * remote connector is identified by its real listener port and remains remote even
 * when the proxy's apparent source is local. Forwarding headers never grant an
 * origin directly; RemoteIpValve must retain the original local port.
 */
@Component
public class LocalNetworkGuardFilter extends OncePerRequestFilter {

    private static final String DENIED_MESSAGE = "当前网络不在公司局域网允许范围内";

    private final ObjectMapper objectMapper;
    private final AuditService auditService;
    private final LocalNetworkAccessPolicy networkPolicy;
    private final TrustedRequestOriginPolicy origins;

    @Autowired
    public LocalNetworkGuardFilter(ObjectMapper objectMapper, AuditService auditService,
                                   LocalNetworkAccessPolicy networkPolicy, TrustedRequestOriginPolicy origins) {
        this.objectMapper = objectMapper;
        this.auditService = auditService;
        this.networkPolicy = networkPolicy;
        this.origins = origins;
    }

    public LocalNetworkGuardFilter(ObjectMapper objectMapper, AuditService auditService,
                                   LocalNetworkAccessPolicy networkPolicy) {
        this(objectMapper, auditService, networkPolicy, null);
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain chain)
            throws ServletException, IOException {
        TrustedRequestOriginPolicy.Origin origin = origins == null
                ? (networkPolicy.isAllowed(request.getRemoteAddr())
                    ? TrustedRequestOriginPolicy.Origin.LOCAL : TrustedRequestOriginPolicy.Origin.UNKNOWN)
                : origins.resolve(request);
        request.setAttribute(TrustedRequestOriginPolicy.ATTRIBUTE, origin);
        if (origin != TrustedRequestOriginPolicy.Origin.UNKNOWN) {
            TrustedRequestOriginPolicy.bind(origin);
            try {
                chain.doFilter(request, response);
            } finally {
                TrustedRequestOriginPolicy.clear();
            }
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
        String path = SecurityRequestPath.withinApplication(request);
        // Actuator stays outside the /api boundary for local health monitoring.
        return !SecurityRequestPath.isApi(path);
    }
}
