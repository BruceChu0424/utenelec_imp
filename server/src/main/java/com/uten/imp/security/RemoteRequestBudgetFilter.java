package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiError;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.DeploymentProperties;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;

/**
 * Remote traffic has a bounded share of application capacity. Rejecting excess
 * work before authentication avoids an unbounded queue or starving office requests.
 * No rejected or interrupted write is replayed here.
 */
@Component
public class RemoteRequestBudgetFilter extends OncePerRequestFilter {
    private final TrustedRequestOriginPolicy origins;
    private final ObjectMapper mapper;
    private final Semaphore permits;
    private final Semaphore healthPermits = new Semaphore(2, true);
    private final MeterRegistry metrics;
    private final Timer timer;

    public RemoteRequestBudgetFilter(TrustedRequestOriginPolicy origins, ObjectMapper mapper,
                                     DeploymentProperties deployment, MeterRegistry metrics) {
        this.origins = origins;
        this.mapper = mapper;
        this.permits = new Semaphore(deployment.getRemoteMaxConcurrentRequests(), true);
        this.metrics = metrics;
        this.timer = Timer.builder("uten.remote.request.duration")
                .description("Remote ERP request duration; no account, URI or business labels")
                .publishPercentiles(0.5, 0.95, 0.99)
                .distributionStatisticExpiry(Duration.ofMinutes(5))
                .register(metrics);
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        String path = SecurityRequestPath.withinApplication(request);
        return !(SecurityRequestPath.isApi(path) || SecurityRequestPath.isHealth(path));
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        String path = SecurityRequestPath.withinApplication(request);
        boolean health = SecurityRequestPath.isHealth(path);
        boolean remote = health
                ? origins.resolve(request) == TrustedRequestOriginPolicy.Origin.REMOTE : origins.isRemoteRequest();
        if (!remote) {
            chain.doFilter(request,response);
            return;
        }
        Semaphore capacity = health ? healthPermits : permits;
        boolean acquired;
        try {
            // Absorb a short five-user page-load burst without making callers
            // wait behind a long operation or returning avoidable rate errors.
            acquired = health ? capacity.tryAcquire() : capacity.tryAcquire(100, TimeUnit.MILLISECONDS);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            acquired = false;
        }
        if (!acquired) {
            metrics.counter(health ? "uten.remote.health.rejected" : "uten.remote.request.rejected").increment();
            response.setStatus(429);
            response.setContentType("application/json");
            response.setCharacterEncoding(StandardCharsets.UTF_8.name());
            response.setHeader("Retry-After","1");
            response.getWriter().write(mapper.writeValueAsString(ApiError.of(
                    ErrorCode.REMOTE_CAPACITY_REJECTED,"当前外网操作较多，请稍后再试；未开始本次业务处理")));
            return;
        }
        Timer.Sample sample = health ? null : Timer.start(metrics);
        try {
            chain.doFilter(request,response);
        } finally {
            if (sample != null) sample.stop(timer);
            capacity.release();
        }
    }

}
