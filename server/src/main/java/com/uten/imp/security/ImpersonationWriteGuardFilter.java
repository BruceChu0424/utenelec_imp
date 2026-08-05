package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
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
import java.time.OffsetDateTime;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;

/**
 * 模拟身份（admin「切换人」）只读守卫：当当前主体带 {@code impersonatedBy}（即正在以他人身份操作）时，
 * 拦截一切写 / 审 / 删 / 导出（POST/PUT/PATCH/DELETE），仅放行查询与显式退出。
 *
 * <p>目的：admin 用模拟身份是为了「验证目标能看到什么」，绝不应真以目标身份改动业务数据。
 * 即使前端绕过直调 API，本守卫在后端兜底返回 403 {@link ErrorCode#IMPERSONATION_READ_ONLY}。
 * 注册顺序在 {@link JwtAuthFilter} 之后，主体已解析完毕。
 */
@Component
@RequiredArgsConstructor
public class ImpersonationWriteGuardFilter extends OncePerRequestFilter {

    private static final Set<String> WRITE_METHODS = Set.of("POST", "PUT", "PATCH", "DELETE");
    // 模拟期间仍需放行的写端点：退出模拟、登出（登出前应已退模拟，此处兜底不硬拦）。
    private static final Set<String> WRITABLE_WHITELIST = Set.of(
            "/api/admin/impersonation/end",
            "/api/auth/logout");

    private final ObjectMapper objectMapper;
    private final AuditService auditService;

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {

        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth != null && auth.getPrincipal() instanceof AuthUser user && user.getImpersonatedBy() != null) {
            String method = request.getMethod() == null ? "" : request.getMethod().toUpperCase(Locale.ROOT);
            if (WRITE_METHODS.contains(method) && !WRITABLE_WHITELIST.contains(stripContextPath(request))) {
                blockWrite(request, response, user.getImpersonatedBy());
                return;
            }
        }
        chain.doFilter(request, response);
    }

    private void blockWrite(HttpServletRequest request, HttpServletResponse response, UUID adminId)
            throws IOException {
        try {
            auditService.logSecurityEvent(
                    request, adminId, null,
                    "impersonation_write_blocked", "forbidden", 403);
        } catch (RuntimeException ignored) {
            // 审计落库失败不得放行写操作（fail-closed）。
        }
        response.setStatus(HttpServletResponse.SC_FORBIDDEN);
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.setCharacterEncoding(StandardCharsets.UTF_8.name());
        var body = objectMapper.createObjectNode()
                .put("timestamp", OffsetDateTime.now().toString())
                .put("status", ErrorCode.IMPERSONATION_READ_ONLY.getHttpStatus())
                .put("code", ErrorCode.IMPERSONATION_READ_ONLY.name())
                .put("message", ErrorCode.IMPERSONATION_READ_ONLY.getDefaultMessage());
        response.getWriter().write(objectMapper.writeValueAsString(body));
    }

    private String stripContextPath(HttpServletRequest request) {
        String path = request.getRequestURI();
        String contextPath = request.getContextPath();
        if (contextPath != null && !contextPath.isEmpty() && path.startsWith(contextPath)) {
            path = path.substring(contextPath.length());
        }
        return path;
    }
}
