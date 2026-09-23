package com.uten.imp.audit;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import java.time.Clock;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * ADR-105 写入口径: 真实操作人与被模拟对象、账号脱敏、写入时分类、例行过期 401 不记、
 * 拒绝事件每分钟一条、详情查看 30 分钟去重。
 */
class AuditServiceWritePolicyTest {

    private final AuditLogRepository repository = mock(AuditLogRepository.class);
    private MutableClock clock;
    private AuditService service;
    private MockHttpServletRequest request;

    @BeforeEach
    void setUp() {
        clock = new MutableClock(Instant.parse("2026-09-23T02:00:00Z"));
        service = new AuditService(repository,
                new AuditDeviceContext(new ObjectMapper().findAndRegisterModules()), clock);
        request = new MockHttpServletRequest("GET", "/api/attachments/1/download-grant");
        request.setRemoteAddr("10.0.0.8");
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(request));
    }

    @AfterEach
    void tearDown() {
        RequestContextHolder.resetRequestAttributes();
    }

    @Test
    void impersonatedDownloadIsRecordedUnderTheRealOperatorAndNamesTheImpersonatedAccount() {
        UUID admin = UUID.randomUUID();
        UUID employee = UUID.randomUUID();
        AuditRequestContext.bindVerifiedActor(request, admin, null, UUID.randomUUID(), employee);

        // 业务服务按当前主体(被模拟的员工)传入操作人。
        service.logExplicit(employee, "13800138000", "attachment_download_grant", "attachments",
                UUID.randomUUID().toString(), "success");

        AuditLog saved = saved().getFirst();
        assertEquals(admin, saved.getActorId());
        assertEquals(employee, saved.getOnBehalfOf());
        assertNull(saved.getActorAccount());
    }

    @Test
    void storedAccountsAreMaskedAndUnverifiedNonNumberInputIsDropped() {
        service.logExplicit(UUID.randomUUID(), "13800138000", "login", "users", null, "success");
        service.logExplicit(null, "Secret#Typed", "login_failed", "users", null, "account_not_found");
        service.logExplicit(null, "13900139000", "login_failed", "users", null, "account_not_found");

        List<AuditLog> rows = saved();
        assertEquals("*******8000", rows.get(0).getActorAccount());
        assertNull(rows.get(1).getActorAccount());
        assertEquals("*******9000", rows.get(2).getActorAccount());
    }

    @Test
    void classificationIsComputedOnceAtWriteTime() {
        service.logSemanticOperation(UUID.randomUUID(), "13800138000", "stock_doc.reverse", "stock_doc",
                "1", "POST", "/api/stock/docs/1/reverse", 200, 12);

        AuditLog saved = saved().getFirst();
        assertEquals("high", saved.getRiskLevel());
        assertEquals("business", saved.getEventCategory());
        assertEquals("business", saved.getEventSource());
    }

    @Test
    void routineExpiredTokenIsNotRecordedButForgedOnesAreAndTheGenericRowIsSuppressed() {
        AuditRequestContext.markExpiredToken(request);
        service.logSecurityEvent(request, null, null, "access_denied", "unauthorized", 401);
        verify(repository, never()).save(any());
        assertTrue(Boolean.TRUE.equals(request.getAttribute(AuditRequestContext.OPERATION_RECORDED_ATTRIBUTE)),
                "the fallback must not write a second row for the same 401");

        MockHttpServletRequest forged = new MockHttpServletRequest("GET", "/api/notices");
        forged.setRemoteAddr("10.0.0.9");
        service.logSecurityEvent(forged, null, null, "access_denied", "unauthorized", 401);
        verify(repository, times(1)).save(any());
    }

    @Test
    void repeatedDenialsFromOneOriginAndPathAreRecordedOncePerMinute() {
        for (int attempt = 0; attempt < 50; attempt++) {
            MockHttpServletRequest denied = new MockHttpServletRequest("GET", "/api/notices/unread-count");
            denied.setRemoteAddr("10.0.0.7");
            service.logSecurityEvent(denied, null, null, "access_denied", "unauthorized", 401);
        }
        verify(repository, times(1)).save(any());

        clock.advanceSeconds(61);
        MockHttpServletRequest later = new MockHttpServletRequest("GET", "/api/notices/unread-count");
        later.setRemoteAddr("10.0.0.7");
        service.logSecurityEvent(later, null, null, "access_denied", "unauthorized", 401);
        verify(repository, times(2)).save(any());
    }

    @Test
    void anonymousCallerCannotDefeatTheThrottleByChangingThePath() {
        // security-11 验收口径: 1000 次匿名请求, 每次换一个路径, 审计只多几行。
        for (int attempt = 0; attempt < 1000; attempt++) {
            MockHttpServletRequest denied = new MockHttpServletRequest(
                    "GET", "/api/x/" + UUID.randomUUID() + "/" + attempt);
            denied.setRemoteAddr("198.51.100.7");
            service.logSecurityEvent(denied, null, null, "access_denied", "unauthorized", 401);
        }
        verify(repository, times(1)).save(any());
        assertTrue(saved().getFirst().getHttpPath().startsWith("/api/x/"),
                "the one kept row still carries the first path as a sample");

        // 同一 IP 换动作/状态码也只到每分钟上限。
        for (int attempt = 0; attempt < 50; attempt++) {
            MockHttpServletRequest other = new MockHttpServletRequest("GET", "/api/y/" + attempt);
            other.setRemoteAddr("198.51.100.7");
            service.logSecurityEvent(other, null, null, "denied_" + attempt, "forbidden", 403);
        }
        verify(repository, times(AuditEventThrottle.ANONYMOUS_ROWS_PER_IP_PER_MINUTE)).save(any());
    }

    @Test
    void distributedAnonymousFloodIsCappedAndCannotReopenCommonKeys() {
        MockHttpServletRequest common = new MockHttpServletRequest("GET", "/api/notices/unread-count");
        common.setRemoteAddr("10.0.0.7");
        service.logSecurityEvent(common, null, null, "access_denied", "unauthorized", 401);

        for (int attempt = 0; attempt < 5_000; attempt++) {
            MockHttpServletRequest flood = new MockHttpServletRequest("GET", "/api/notices");
            flood.setRemoteAddr("203.0.113." + (attempt % 250) + "-" + attempt);
            service.logSecurityEvent(flood, null, null, "access_denied", "unauthorized", 401);
        }
        verify(repository, times(AuditEventThrottle.ANONYMOUS_ROWS_PER_MINUTE)).save(any());

        // 刷键不会把常用键的窗口提前清掉。
        MockHttpServletRequest again = new MockHttpServletRequest("GET", "/api/notices/unread-count");
        again.setRemoteAddr("10.0.0.7");
        service.logSecurityEvent(again, null, null, "access_denied", "unauthorized", 401);
        verify(repository, times(AuditEventThrottle.ANONYMOUS_ROWS_PER_MINUTE)).save(any());

        clock.advanceSeconds(61);
        service.logSecurityEvent(again, null, null, "access_denied", "unauthorized", 401);
        verify(repository, times(AuditEventThrottle.ANONYMOUS_ROWS_PER_MINUTE + 1)).save(any());
    }

    @Test
    void anonymousFailedRequestRowsShareTheThrottleButSignedInFailuresAreKept() {
        for (int attempt = 0; attempt < 200; attempt++) {
            MockHttpServletRequest refresh = new MockHttpServletRequest("POST", "/api/auth/refresh/" + attempt);
            refresh.setRemoteAddr("198.51.100.9");
            RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(refresh));
            service.logSemanticOperation(null, null, "auth.refresh", "auth", null, "POST",
                    refresh.getRequestURI(), 401, 3);
            service.logHttpOperation(null, null, "GET", refresh.getRequestURI(), "api/auth/refresh", 404, 1);
        }
        verify(repository, times(2)).save(any());

        UUID actor = UUID.randomUUID();
        for (int attempt = 0; attempt < 3; attempt++) {
            MockHttpServletRequest signedIn = new MockHttpServletRequest("POST", "/api/sales/orders/1/approve");
            AuditRequestContext.bindVerifiedActor(signedIn, actor, "13800138000", UUID.randomUUID());
            RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(signedIn));
            service.logSemanticOperation(actor, "13800138000", "sales_order.approve", "sales_order", "1",
                    "POST", signedIn.getRequestURI(), 409, 5);
        }
        verify(repository, times(5)).save(any());
    }

    @Test
    void detailViewsAreDeduplicatedPerActorTargetAndSessionForThirtyMinutes() {
        UUID actor = UUID.randomUUID();
        UUID session = UUID.randomUUID();
        UUID target = UUID.randomUUID();
        AuditRequestContext.bindVerifiedActor(request, actor, "13800138000", session);
        when(repository.existsByActorIdAndActionAndTargetTypeAndTargetIdAndSessionIdAndCreatedAtAfter(
                eq(actor), eq("view_material_analysis_detail"), eq("production_material_analyses"),
                eq(target.toString()), eq(session), any(OffsetDateTime.class)))
                .thenReturn(false, true);

        service.logSuccessfulDetailView(actor, "13800138000", "view_material_analysis_detail",
                "production_material_analyses", target, "物料分析", "MA-001", null);
        service.logSuccessfulDetailView(actor, "13800138000", "view_material_analysis_detail",
                "production_material_analyses", target, "物料分析", "MA-001", null);

        verify(repository, times(1)).save(any());
        ArgumentCaptor<OffsetDateTime> since = ArgumentCaptor.forClass(OffsetDateTime.class);
        verify(repository, times(2)).existsByActorIdAndActionAndTargetTypeAndTargetIdAndSessionIdAndCreatedAtAfter(
                eq(actor), eq("view_material_analysis_detail"), eq("production_material_analyses"),
                eq(target.toString()), eq(session), since.capture());
        assertEquals(OffsetDateTime.parse("2026-09-23T01:30:00Z").toInstant(), since.getValue().toInstant());
    }

    private List<AuditLog> saved() {
        ArgumentCaptor<AuditLog> captor = ArgumentCaptor.forClass(AuditLog.class);
        verify(repository, org.mockito.Mockito.atLeastOnce()).save(captor.capture());
        return captor.getAllValues();
    }

    private static final class MutableClock extends Clock {
        private Instant now;

        private MutableClock(Instant now) {
            this.now = now;
        }

        void advanceSeconds(long seconds) {
            now = now.plusSeconds(seconds);
        }

        @Override
        public java.time.ZoneId getZone() {
            return ZoneOffset.UTC;
        }

        @Override
        public Clock withZone(java.time.ZoneId zone) {
            return this;
        }

        @Override
        public Instant instant() {
            return now;
        }
    }
}
