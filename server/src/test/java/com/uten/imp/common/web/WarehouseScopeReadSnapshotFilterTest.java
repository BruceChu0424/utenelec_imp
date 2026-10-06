package com.uten.imp.common.web;

import com.uten.imp.application.port.WarehouseTaskScopePort.Role;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseAccess;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.features.master.warehouse.WarehouseDataScopeService;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.servlet.DispatcherType;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

import java.io.IOException;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.Mockito.RETURNS_SELF;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * ADR-149 §2.1 只读请求整请求一个仓库范围快照: GET/HEAD 一次请求只解析一次; 写请求每次实时;
 * 窗口在处理抛错、异步继续之后都已关闭, 不会跟着线程池的线程进到下一个请求。
 * 用真实 {@link WarehouseDataScopeService}(只替换数据库), 数的是 {@code fn_user_warehouse_access} 调用次数。
 */
class WarehouseScopeReadSnapshotFilterTest {

    private final JdbcClient jdbc = mock(JdbcClient.class);
    private final SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
    private final WarehouseDataScopeService scopes = new WarehouseDataScopeService(jdbc, currentUser);
    private final WarehouseScopeReadSnapshotFilter filter = new WarehouseScopeReadSnapshotFilter(scopes);
    private final AtomicInteger resolutions = new AtomicInteger();

    @BeforeEach
    @SuppressWarnings({"unchecked", "rawtypes"})
    void stubDatabase() {
        JdbcClient.StatementSpec access = mock(JdbcClient.StatementSpec.class, RETURNS_SELF);
        JdbcClient.MappedQuerySpec resolved = mock(JdbcClient.MappedQuerySpec.class);
        when(jdbc.sql(contains("fn_user_warehouse_access"))).thenReturn(access);
        when(access.query(any(RowMapper.class))).thenReturn(resolved);
        when(resolved.single()).thenAnswer(call -> {
            resolutions.incrementAndGet();
            return new WarehouseAccess(Role.KEEPER, List.of(), new WarehouseTaskScope(true, List.of(), false), true);
        });
        when(currentUser.id()).thenReturn(Optional.of(UUID.fromString("00000000-0000-0000-0000-00000000d001")));
    }

    @Test
    void aReadRequestResolvesTheScopeOnceAndClosesTheWindowWhenItReturns() throws Exception {
        for (String method : List.of("GET", "HEAD")) {
            resolutions.set(0);
            filter.doFilter(request(method), new MockHttpServletResponse(), resolveThreeTimes());
            assertThat(resolutions).as(method).hasValue(1);
            assertLive();
        }
    }

    @Test
    void writeRequestsStayLive() throws Exception {
        for (String method : List.of("POST", "PUT", "PATCH", "DELETE")) {
            resolutions.set(0);
            filter.doFilter(request(method), new MockHttpServletResponse(), resolveThreeTimes());
            assertThat(resolutions).as(method).hasValue(3);
        }
    }

    @Test
    void aFailingReadRequestRethrowsTheSameFailureWithTheWindowClosed() {
        RuntimeException runtime = new IllegalStateException("handler failed");
        IOException io = new IOException("client went away");
        ServletException servlet = new ServletException("dispatch failed");
        for (Exception failure : List.of(runtime, io, servlet)) {
            FilterChain chain = (request, response) -> {
                scopes.access();
                scopes.access();
                if (failure instanceof IOException checked) throw checked;
                if (failure instanceof ServletException checked) throw checked;
                throw (RuntimeException) failure;
            };
            assertThatThrownBy(() -> filter.doFilter(request("GET"), new MockHttpServletResponse(), chain))
                    .isSameAs(failure);
            assertLive();
        }
    }

    /** 线程池里同一条线程: 上一个只读请求抛错退出, 下一个写请求照样实时解析。 */
    @Test
    void theWindowNeverLeaksIntoTheNextRequestOnAPooledThread() throws Exception {
        try (var pool = Executors.newSingleThreadExecutor()) {
            pool.submit(() -> {
                assertThatThrownBy(() -> filter.doFilter(request("GET"), new MockHttpServletResponse(),
                        (request, response) -> {
                            scopes.access();
                            throw new IllegalStateException("boom");
                        })).isInstanceOf(IllegalStateException.class);
                return null;
            }).get(10, TimeUnit.SECONDS);
            resolutions.set(0);
            pool.submit(() -> {
                filter.doFilter(request("POST"), new MockHttpServletResponse(), resolveThreeTimes());
                return null;
            }).get(10, TimeUnit.SECONDS);
        }
        assertThat(resolutions).hasValue(3);
    }

    /** 异步响应: 处理线程返回即关窗口; 异步分派(继续写响应的那一段)不再开窗口, 实时解析。 */
    @Test
    void asyncProcessingGetsNoWindowAfterTheRequestThreadReturns() throws Exception {
        MockHttpServletRequest started = request("GET");
        started.setAsyncSupported(true);
        filter.doFilter(started, new MockHttpServletResponse(), (request, response) -> {
            scopes.access();
            request.startAsync();
        });
        assertThat(resolutions).hasValue(1);
        assertLive();

        resolutions.set(0);
        MockHttpServletRequest dispatched = request("GET");
        dispatched.setDispatcherType(DispatcherType.ASYNC);
        filter.doFilter(dispatched, new MockHttpServletResponse(), resolveThreeTimes());
        assertThat(resolutions).hasValue(3);
    }

    private FilterChain resolveThreeTimes() {
        return (request, response) -> {
            scopes.access();
            scopes.current(null);
            scopes.access();
        };
    }

    /** 窗口已关: 之后每次判定都实时解析。 */
    private void assertLive() {
        int before = resolutions.get();
        scopes.access();
        scopes.access();
        assertThat(resolutions).hasValue(before + 2);
    }

    private static MockHttpServletRequest request(String method) {
        MockHttpServletRequest request = new MockHttpServletRequest(method, "/api/stock/docs");
        request.setRequestURI("/api/stock/docs");
        return request;
    }
}
