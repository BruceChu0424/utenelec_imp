package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import org.springframework.web.servlet.HandlerInterceptor;

import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.Semaphore;

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

    private static final String CONCURRENCY_PERMIT_ATTRIBUTE =
            ExportRateLimitInterceptor.class.getName() + ".permit";

    private final ExportRateLimiter rateLimiter;
    private final SecurityContextCurrentUser currentUser;
    private final Semaphore concurrencyGate;

    public ExportRateLimitInterceptor(
            ExportRateLimiter rateLimiter,
            SecurityContextCurrentUser currentUser,
            @Value("${uten.security.export-max-concurrent:2}") int maxConcurrent) {
        this.rateLimiter = rateLimiter;
        this.currentUser = currentUser;
        this.concurrencyGate = new Semaphore(Math.max(1, maxConcurrent), true);
    }

    @Override
    public boolean preHandle(HttpServletRequest request, HttpServletResponse response, Object handler) {
        if (!"POST".equalsIgnoreCase(request.getMethod())) {
            return true;
        }
        Optional<UUID> userId = currentUser.id();
        if (userId.isEmpty()) {
            return true;
        }
        rateLimiter.check(userId.get());
        if (!concurrencyGate.tryAcquire()) {
            throw new ApiException(ErrorCode.RATE_LIMITED, "导出任务繁忙，请稍后重试");
        }
        request.setAttribute(CONCURRENCY_PERMIT_ATTRIBUTE, Boolean.TRUE);
        return true;
    }

    @Override
    public void afterCompletion(
            HttpServletRequest request,
            HttpServletResponse response,
            Object handler,
            Exception exception) {
        if (Boolean.TRUE.equals(request.getAttribute(CONCURRENCY_PERMIT_ATTRIBUTE))) {
            request.removeAttribute(CONCURRENCY_PERMIT_ATTRIBUTE);
            concurrencyGate.release();
        }
    }
}
