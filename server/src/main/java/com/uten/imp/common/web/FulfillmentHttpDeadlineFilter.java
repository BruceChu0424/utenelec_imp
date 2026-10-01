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
        return java.util.List.of("production", "stock/docs", "warehouse", "procurement/inspection",
                        "purchase", "subcontract", "sales", "finance")
                .stream().noneMatch(prefix -> path.equals("/api/" + prefix) || path.startsWith("/api/" + prefix + "/"));
    }

    @Override protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        try (var deadline = FulfillmentCommandDeadline.openHttpRequest(budget)) {
            chain.doFilter(request, response);
        }
    }
}
