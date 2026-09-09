package com.uten.imp.features.admin.systemtest;

import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.time.OffsetDateTime;

/**
 * 业务数据清空期间的 API 排水过滤器：把 psql 停机版「零其它客户端连接」的
 * 静默前提搬进运行中的应用。
 *
 * <p>清空事务要对 222 张业务表拿 ACCESS EXCLUSIVE 锁。排水期间（含清空执行中）
 * 除清空端点本身外的全部 /api 请求直接回 503，不进入控制器、不开事务，
 * 避免与 TRUNCATE 争锁导致清空失败或清空后补写残留行；actuator/健康检查
 * 不在 /api 前缀下，不受影响，不会误伤探活。</p>
 *
 * <p>普通请求同时进入在途计数，{@link BusinessDataResetDrainGate#beginDrain}
 * 等计数归零后才开始清空；清空端点自身豁免计数（它在排水开始前已进入，
 * 否则会自己等自己）。注册顺序在 Spring Security 之前（见
 * {@code BusinessDataResetWebConfig}），保证计数覆盖鉴权查询。</p>
 */
public class BusinessDataResetDrainFilter extends OncePerRequestFilter {

    /** 清空端点路径（过滤器按去 contextPath 后的绝对路径精确匹配豁免）。 */
    static final String RESET_PATH = "/api/system-test/business-data/reset";
    static final String ATTACHMENT_PREPARE_PATH = "/api/system-test/business-data/attachments/prepare";

    private final BusinessDataResetDrainGate gate;
    private final ObjectMapper objectMapper;

    public BusinessDataResetDrainFilter(BusinessDataResetDrainGate gate, ObjectMapper objectMapper) {
        this.gate = gate;
        this.objectMapper = objectMapper;
    }

    @Override
    protected void doFilterInternal(
            HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        String path = request.getRequestURI();
        String contextPath = request.getContextPath();
        if (contextPath != null && !contextPath.isEmpty() && path.startsWith(contextPath)) {
            path = path.substring(contextPath.length());
        }
        if (RESET_PATH.equals(path) || ATTACHMENT_PREPARE_PATH.equals(path)) {
            // 清空端点自身：不计数、不拦截（排水等它之外的所有请求）。
            chain.doFilter(request, response);
            return;
        }
        if (!gate.tryEnter()) {
            writeServiceUnavailable(response);
            return;
        }
        try {
            chain.doFilter(request, response);
        } finally {
            gate.leave();
        }
    }

    private void writeServiceUnavailable(HttpServletResponse response) throws IOException {
        response.setStatus(HttpServletResponse.SC_SERVICE_UNAVAILABLE);
        response.setContentType("application/json");
        response.setCharacterEncoding(StandardCharsets.UTF_8.name());
        var body = objectMapper.createObjectNode()
                .put("timestamp", OffsetDateTime.now().toString())
                .put("status", HttpServletResponse.SC_SERVICE_UNAVAILABLE)
                .put("code", "SERVICE_UNAVAILABLE")
                .put("message", "系统正在清空业务数据，请稍后重新登录");
        response.getWriter().write(objectMapper.writeValueAsString(body));
    }
}
