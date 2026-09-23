package com.uten.imp.audit;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.web.method.HandlerMethod;
import org.springframework.web.servlet.HandlerMapping;

import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/** ADR-105 请求审计口径: 写请求记语义事件, 成功读取默认不记, 失败一律留痕。 */
class UserOperationAuditInterceptorTest {

    private AuditService auditService;
    private UserOperationAuditInterceptor interceptor;
    private SecurityContextCurrentUser currentUser;
    private UUID userId;

    /** 模拟一个真实控制器: 类名推导资源, 方法名推导动作。 */
    static class SalesOrderController {
        public void approve(UUID id) {
        }

        @AuditAutomaticWrite("测试: 页面自动发起")
        public void heartbeat(UUID id) {
        }

        public void list() {
        }

        @AuditedRead("测试: 含个人资料的读取")
        public void roster() {
        }
    }

    @BeforeEach
    void setUp() {
        currentUser = mock(SecurityContextCurrentUser.class);
        AuthUser user = mock(AuthUser.class);
        auditService = mock(AuditService.class);
        userId = UUID.randomUUID();

        when(user.getId()).thenReturn(userId);
        when(user.getLoginAccount()).thenReturn("auditor");
        when(currentUser.get()).thenReturn(Optional.of(user));
        interceptor = new UserOperationAuditInterceptor(currentUser, auditService);
    }

    @Test
    void successfulWriteBecomesOneSemanticBusinessEventWithTheTargetFromThePath() throws Exception {
        MockHttpServletRequest request = request("POST", "/api/sales/orders/123/approve");
        request.setAttribute(HandlerMapping.URI_TEMPLATE_VARIABLES_ATTRIBUTE, Map.of("id", "123"));
        request.setContent("password=must-not-be-audited".getBytes());

        run(request, new MockHttpServletResponse(), handler("approve", UUID.class), null);

        verify(auditService).logSemanticOperation(
                eq(userId), eq("auditor"), eq("sales_order.approve"), eq("sales_order"), eq("123"),
                eq("POST"), eq("/api/sales/orders/123/approve"), eq(200), anyLong());
    }

    @Test
    void failedWriteKeepsItsSemanticActionAndStatus() throws Exception {
        MockHttpServletRequest request = request("POST", "/api/sales/orders/123/approve");
        request.setAttribute(HandlerMapping.URI_TEMPLATE_VARIABLES_ATTRIBUTE, Map.of("id", "123"));
        MockHttpServletResponse response = new MockHttpServletResponse();
        response.setStatus(409);

        run(request, response, handler("approve", UUID.class), null);

        verify(auditService).logSemanticOperation(
                eq(userId), eq("auditor"), eq("sales_order.approve"), eq("sales_order"), eq("123"),
                eq("POST"), eq("/api/sales/orders/123/approve"), eq(409), anyLong());
    }

    @Test
    void unhandledExceptionIsRecordedAsServerFailure() throws Exception {
        MockHttpServletRequest request = request("POST", "/api/sales/orders/123/approve");

        run(request, new MockHttpServletResponse(), handler("approve", UUID.class),
                new IllegalStateException("controller failed"));

        verify(auditService).logSemanticOperation(
                eq(userId), eq("auditor"), eq("sales_order.approve"), eq("sales_order"), isNull(),
                eq("POST"), eq("/api/sales/orders/123/approve"), eq(500), anyLong());
    }

    @Test
    void explicitBusinessEventReplacesTheSemanticEvent() throws Exception {
        MockHttpServletRequest request = request("POST", "/api/sales/orders/123/approve");
        AuditRequestContext.markMeaningfulEventRecorded(request);

        run(request, new MockHttpServletResponse(), handler("approve", UUID.class), null);

        verifyNoInteractions(auditService);
    }

    @Test
    void durableSuccessEventThenFailureStillLeavesTheFailureRow() throws Exception {
        // 导出类接口先独立提交「导出成功」再开始输出, 输出中途 500: 不能只剩一条成功记录。
        MockHttpServletRequest request = request("POST", "/api/sales/orders/export");
        AuditRequestContext.markDurableEventRecorded(request, false);
        MockHttpServletResponse response = new MockHttpServletResponse();
        response.setStatus(500);

        run(request, response, handler("approve", UUID.class), null);

        verify(auditService).logSemanticOperation(
                eq(userId), eq("auditor"), eq("sales_order.approve"), eq("sales_order"), isNull(),
                eq("POST"), eq("/api/sales/orders/export"), eq(500), anyLong());
    }

    @Test
    void durableFailureEventExplainsTheFailedRequest() throws Exception {
        // 登录失败这类失败事件已经独立提交, 失败请求不再补第二行。
        MockHttpServletRequest request = request("POST", "/api/sales/orders/123/approve");
        AuditRequestContext.markDurableEventRecorded(request, true);
        MockHttpServletResponse response = new MockHttpServletResponse();
        response.setStatus(401);

        run(request, response, handler("approve", UUID.class), null);

        verifyNoInteractions(auditService);
    }

    @Test
    void automaticSessionWriteIsQuietOnSuccessButKeptOnFailure() throws Exception {
        run(request("POST", "/api/task-claims/x/y/heartbeat"), new MockHttpServletResponse(),
                handler("heartbeat", UUID.class), null);
        verifyNoInteractions(auditService);

        MockHttpServletResponse failed = new MockHttpServletResponse();
        failed.setStatus(409);
        run(request("POST", "/api/task-claims/x/y/heartbeat"), failed, handler("heartbeat", UUID.class), null);
        verify(auditService).logSemanticOperation(
                eq(userId), eq("auditor"), eq("sales_order.heartbeat"), eq("sales_order"), isNull(),
                eq("POST"), eq("/api/task-claims/x/y/heartbeat"), eq(409), anyLong());
    }

    @Test
    void successfulReadsAreNotRecordedUnlessDeclaredSensitive() throws Exception {
        run(request("GET", "/api/production/workshop-tasks/count"), new MockHttpServletResponse(),
                handler("list"), null);
        verifyNoInteractions(auditService);

        run(request("GET", "/api/org/employees"), new MockHttpServletResponse(), handler("roster"), null);
        verify(auditService).logHttpOperation(
                eq(userId), eq("auditor"), eq("GET"), eq("/api/org/employees"), eq("api/org/employees"),
                eq(200), anyLong());
    }

    @Test
    void failedReadIsRetained() throws Exception {
        MockHttpServletResponse response = new MockHttpServletResponse();
        response.setStatus(503);

        run(request("GET", "/api/production/schedule/pending-count"), response, handler("list"), null);

        verify(auditService).logHttpOperation(
                eq(userId), eq("auditor"), eq("GET"),
                eq("/api/production/schedule/pending-count"),
                eq("api/production/schedule"), eq(503), anyLong());
    }

    @Test
    void anonymousMalformedLoginWithoutHandlerMethodKeepsAGenericFailureRow() {
        when(currentUser.get()).thenReturn(Optional.empty());
        MockHttpServletRequest request = request("POST", "/api/auth/login");
        request.setQueryString("debug=secret-query-value");
        MockHttpServletResponse response = new MockHttpServletResponse();
        response.setStatus(400);

        run(request, response, new Object(), null);

        verify(auditService).logHttpOperation(
                isNull(), isNull(), eq("POST"), eq("/api/auth/login"), eq("api/auth/login"),
                eq(400), anyLong());
    }

    @Test
    void targetPrefersIdThenTheSingleIdLikeVariable() {
        MockHttpServletRequest byId = request("POST", "/x");
        byId.setAttribute(HandlerMapping.URI_TEMPLATE_VARIABLES_ATTRIBUTE, Map.of("id", "a", "lineId", "b"));
        assertEquals("a", UserOperationAuditInterceptor.targetId(byId));

        MockHttpServletRequest byIdLike = request("POST", "/x");
        byIdLike.setAttribute(HandlerMapping.URI_TEMPLATE_VARIABLES_ATTRIBUTE,
                Map.of("targetType", "t", "analysisId", "b"));
        assertEquals("b", UserOperationAuditInterceptor.targetId(byIdLike));

        MockHttpServletRequest ambiguous = request("POST", "/x");
        ambiguous.setAttribute(HandlerMapping.URI_TEMPLATE_VARIABLES_ATTRIBUTE,
                Map.of("orderId", "a", "lineId", "b"));
        assertNull(UserOperationAuditInterceptor.targetId(ambiguous));
    }

    private void run(MockHttpServletRequest request, MockHttpServletResponse response, Object handler,
                     Exception exception) {
        interceptor.preHandle(request, response, handler);
        interceptor.afterCompletion(request, response, handler, exception);
    }

    private static MockHttpServletRequest request(String method, String path) {
        return new MockHttpServletRequest(method, path);
    }

    private static HandlerMethod handler(String name, Class<?>... parameterTypes) {
        try {
            return new HandlerMethod(new SalesOrderController(),
                    SalesOrderController.class.getMethod(name, parameterTypes));
        } catch (NoSuchMethodException exception) {
            throw new IllegalStateException(exception);
        }
    }
}
