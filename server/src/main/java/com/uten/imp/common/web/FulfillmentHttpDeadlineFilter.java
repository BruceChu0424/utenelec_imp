package com.uten.imp.common.web;

import com.uten.imp.application.concurrency.FulfillmentCommandDeadline;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.time.Duration;
import java.util.Set;

/** One server-side receipt-to-command deadline. No post-COMMIT timeout and no automatic HTTP write retry. */
public final class FulfillmentHttpDeadlineFilter extends OncePerRequestFilter {
    private static final Set<String> WRITE_METHODS = Set.of("POST", "PUT", "PATCH", "DELETE");
    private final Duration budget;

    public FulfillmentHttpDeadlineFilter(Duration budget) {
        if (budget == null || budget.isZero() || budget.isNegative()) throw new IllegalArgumentException("HTTP command budget must be positive");
        this.budget = budget;
    }

    @Override protected boolean shouldNotFilter(HttpServletRequest request) {
        if (!WRITE_METHODS.contains(request.getMethod())) return true;
        String path = request.getRequestURI().substring(request.getContextPath().length());
        if (fileEndpoint(path)) return true;
        return java.util.List.of("production", "stock/docs", "warehouse", "procurement/inspection",
                        "purchase", "subcontract", "sales", "finance")
                .stream().noneMatch(prefix -> path.equals("/api/" + prefix) || path.startsWith("/api/" + prefix + "/"));
    }

    /**
     * 文件产出端点(导出/下载)是携带过滤条件的读,不吃履约命令预算——否则 40 秒的请求
     * 截止时间会把导出事务(2 分钟口径)整体压住。与 WebMvcConfig 导出限流拦截器的
     * 端点口径保持一致(2026-11-08)。
     */
    private static boolean fileEndpoint(String path) {
        if (!path.startsWith("/api/")) return false;
        if (path.endsWith("/export")) return true;
        return path.matches("/api/report-export-jobs/[^/]+/download")
                || path.matches("/api/payroll/slips/[^/]+/download");
    }

    @Override protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        try (var deadline = FulfillmentCommandDeadline.openHttpRequest(budget)) {
            chain.doFilter(request, response);
        }
    }
}
