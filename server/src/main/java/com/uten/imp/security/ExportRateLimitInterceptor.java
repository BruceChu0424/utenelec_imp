package com.uten.imp.security;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.servlet.HandlerInterceptor;

/**
 * 导出限流拦截器：POST 导出端点进入 Controller 前，按当前用户做每分钟频率检查。
 *
 * <p>集中在一处拦截所有模块的导出端点（6 报表族 + 5 主档），无需各 Controller 改动。
 * 拦截器在 DispatcherServlet 内、Controller 前；JwtAuthFilter（Spring Security Filter）
 * 已先于 DispatcherServlet 设置 SecurityContext，故此处 {@link SecurityContextCurrentUser#id()} 可用。
 *
 * <p>仅拦 POST（导出端点都是 POST）；非 POST 或未认证（id 为空）放行（交由后续鉴权 401/403 处理）。
 */
@Component
public class ExportRateLimitInterceptor implements HandlerInterceptor {

    private final ExportRateLimiter rateLimiter;
    private final SecurityContextCurrentUser currentUser;

    public ExportRateLimitInterceptor(ExportRateLimiter rateLimiter, SecurityContextCurrentUser currentUser) {
        this.rateLimiter = rateLimiter;
        this.currentUser = currentUser;
    }

    @Override
    public boolean preHandle(HttpServletRequest request, HttpServletResponse response, Object handler) {
        if (!"POST".equalsIgnoreCase(request.getMethod())) {
            return true;
        }
        currentUser.id().ifPresent(rateLimiter::check); // 超限在 check 内抛 RATE_LIMITED（全局异常→429）
        return true;
    }
}
