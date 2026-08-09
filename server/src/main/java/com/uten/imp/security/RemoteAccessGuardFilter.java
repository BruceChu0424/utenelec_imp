package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.DeploymentProperties;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.http.MediaType;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.time.OffsetDateTime;

/**
 * 云端（外网）访问门禁：仅当部署在云端（uten.deployment.site=cloud）时生效。
 * 已认证员工主体若 remote_access=FALSE → 一律拒绝（403）。授权开关由超管通过
 * PUT /api/admin/users/{id}/remote-access 管理；变更即时 bump auth_version 失效旧 token。
 *
 * <p>注册顺序在 {@link JwtAuthFilter} 之后（主体已解析完毕）。local 站点为空操作（公司内网全员可用）。
 * {@link DeploymentProperties} 经 {@link ObjectProvider} 注入：在 @WebMvcTest 切片等不含该 bean 的
 * 上下文里取不到时按 local 处理（空操作），避免破坏窄切片测试。
 */
@Component
@RequiredArgsConstructor
public class RemoteAccessGuardFilter extends OncePerRequestFilter {

    private final ObjectMapper objectMapper;
    private final AuditService auditService;
    private final ObjectProvider<DeploymentProperties> deploymentProvider;

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        DeploymentProperties deployment = deploymentProvider.getIfAvailable();
        if (deployment == null || !"cloud".equalsIgnoreCase(deployment.getSite())) {
            chain.doFilter(request, response);
            return;
        }
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth != null && auth.getPrincipal() instanceof AuthUser user
                && !user.isVisitor() && !user.isRemoteAccess()) {
            block(request, response, user);
            return;
        }
        chain.doFilter(request, response);
    }

    private void block(HttpServletRequest request, HttpServletResponse response, AuthUser user)
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
        var body = objectMapper.createObjectNode()
                .put("timestamp", OffsetDateTime.now().toString())
                .put("status", ErrorCode.FORBIDDEN.getHttpStatus())
                .put("code", ErrorCode.FORBIDDEN.name())
                .put("message", "该账号未授权外网(云端)访问");
        response.getWriter().write(objectMapper.writeValueAsString(body));
    }
}
