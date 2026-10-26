package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiError;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
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
 * 外网访问门禁：可信remote connector及历史cloud站点均执行。
 * 员工未获个人授权或全局策略关闭时拒绝（403）。授权开关由超管通过
 * PUT /api/admin/users/{id}/remote-access 管理；变更即时 bump auth_version 失效旧 token。
 *
 * <p>注册顺序在 {@link JwtAuthFilter} 之后（主体与最新策略已解析），MFA门禁之前。
 */
@Component
@RequiredArgsConstructor
public class RemoteAccessGuardFilter extends OncePerRequestFilter {

    private final ObjectMapper objectMapper;
    private final AuditService auditService;
    private final RemoteAccessPolicy remoteAccessPolicy;

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        return PublicPlatformBrandingRequest.matches(request) || PublicMaintenanceRequest.matches(request);
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        String path = SecurityRequestPath.withinApplication(request);
        if (remoteAccessPolicy.isRemoteRequest() && !remoteAccessPolicy.isCloud()
                && (path.equals("/api/website-inquiries/ingest")
                    || path.equals("/api/visitor") || path.startsWith("/api/visitor/"))) {
            block(request,response,null,new ApiException(ErrorCode.FORBIDDEN,"当前远程入口仅供获授权员工使用"));
            return;
        }
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
                    request, user == null ? null : user.getId(), null,
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
