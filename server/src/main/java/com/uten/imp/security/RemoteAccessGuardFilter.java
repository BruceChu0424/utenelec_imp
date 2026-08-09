package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiError;
import com.uten.imp.common.web.ApiException;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.http.MediaType;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

/**
 * 云端（外网）访问门禁：仅当部署在云端（uten.deployment.site=cloud）时生效。
 * 已认证员工主体若 remote_access=FALSE → 一律拒绝（403）。授权开关由超管通过
 * PUT /api/admin/users/{id}/remote-access 管理；变更即时 bump auth_version 失效旧 token。
 *
 * <p>注册顺序在 {@link JwtAuthFilter} 之后（主体已解析完毕）。local 站点为空操作。
 */
@Component
@RequiredArgsConstructor
public class RemoteAccessGuardFilter extends OncePerRequestFilter {

    private final ObjectMapper objectMapper;
    private final AuditService auditService;
    private final RemoteAccessPolicy remoteAccessPolicy;

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth != null && auth.getPrincipal() instanceof AuthUser user) {
            try {
                remoteAccessPolicy.requireAuthenticatedAccess(user);
            } catch (ApiException denied) {
                block(request, response, user, denied);
                return;
            }
        }
        chain.doFilter(request, response);
    }

    private void block(HttpServletRequest request, HttpServletResponse response,
                       AuthUser user, ApiException denied)
            throws IOException {
        try {
            auditService.logSecurityEvent(
                    request, user.getId(), null,
                    "remote_access_denied", "forbidden", 403);
        } catch (RuntimeException ignored) {
            // 审计落库失败不得放行（fail-closed）。
        }
        response.setStatus(HttpServletResponse.SC_FORBIDDEN);
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.setCharacterEncoding(StandardCharsets.UTF_8.name());
        response.getWriter().write(objectMapper.writeValueAsString(
                ApiError.of(denied.getCode(), denied.getMessage())));
    }
}
