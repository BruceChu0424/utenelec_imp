package com.uten.imp.audit;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class AuditDetailViewRecorderTest {

    @Test
    void recorderUsesAuthenticatedUuidAndBuildsStableHistoryFallback() {
        AuditService audit = mock(AuditService.class);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        AuthUser actor = mock(AuthUser.class);
        UUID actorId = UUID.randomUUID();
        UUID resourceId = UUID.randomUUID();
        when(actor.getId()).thenReturn(actorId);
        when(actor.getLoginAccount()).thenReturn("seller01");
        when(currentUser.get()).thenReturn(Optional.of(actor));
        AuditDetailViewRecorder recorder = new AuditDetailViewRecorder(audit, currentUser);

        recorder.record(
                "view_sales_order_detail",
                "sales_orders",
                resourceId,
                null,
                88,
                "销售订货单");

        verify(audit).logSuccessfulDetailView(
                actorId,
                "seller01",
                "view_sales_order_detail_history",
                "sales_orders",
                resourceId,
                "销售订货单(旧系统编号 88)");
    }

    @Test
    void missingAuthenticatedActorFailsClosedBeforeWriting() {
        AuditService audit = mock(AuditService.class);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.get()).thenReturn(Optional.empty());
        AuditDetailViewRecorder recorder = new AuditDetailViewRecorder(audit, currentUser);

        assertThrows(IllegalStateException.class, () -> recorder.record(
                "view_sales_quote_detail",
                "sales_quotes",
                UUID.randomUUID(),
                "BJ-001",
                null,
                "销售报价单"));
        verifyNoInteractions(audit);
    }

    @Test
    void verifiedRealActorWinsOverImpersonatedCurrentUser() {
        AuditService audit = mock(AuditService.class);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        AuthUser impersonated = mock(AuthUser.class);
        when(impersonated.getId()).thenReturn(UUID.randomUUID());
        when(impersonated.getLoginAccount()).thenReturn("impersonated-user");
        when(currentUser.get()).thenReturn(Optional.of(impersonated));
        UUID realActorId = UUID.randomUUID();
        MockHttpServletRequest request = new MockHttpServletRequest(
                "GET", "/api/sales/orders/real");
        AuditRequestContext.bindVerifiedActor(request, realActorId, "real-admin");
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(request));
        UUID resourceId = UUID.randomUUID();
        try {
            new AuditDetailViewRecorder(audit, currentUser).record(
                    "view_sales_order_detail", "sales_orders", resourceId,
                    "SO-001", null, "销售订货单");
        } finally {
            RequestContextHolder.resetRequestAttributes();
        }

        verify(audit).logSuccessfulDetailView(
                realActorId, "real-admin", "view_sales_order_detail",
                "sales_orders", resourceId, "SO-001");
    }

    @Test
    void auditServiceStoresOnlyUuidBillNumberAndHistoryMetadataAndSuppressesGenericGet()
            throws Exception {
        AuditLogRepository repository = mock(AuditLogRepository.class);
        AuditService service = new AuditService(
                repository,
                new AuditDeviceContext(new ObjectMapper().findAndRegisterModules()));
        MockHttpServletRequest request = new MockHttpServletRequest(
                "GET", "/api/sales/orders/ignored");
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(request));
        UUID resourceId = UUID.randomUUID();
        try {
            service.logSuccessfulDetailView(
                    UUID.randomUUID(),
                    "seller01",
                    "view_sales_order_detail",
                    "sales_orders",
                    resourceId,
                    "SO-2026-001");
        } finally {
            RequestContextHolder.resetRequestAttributes();
        }

        ArgumentCaptor<AuditLog> saved = ArgumentCaptor.forClass(AuditLog.class);
        verify(repository).save(saved.capture());
        AuditLog value = saved.getValue();
        assertEquals(resourceId.toString(), value.getTargetId());
        var metadata = new ObjectMapper().readTree(value.getAfter());
        assertEquals("business_detail_view",
                metadata.path("view_metadata_kind").asText());
        assertEquals("SO-2026-001",
                metadata.path("view_display_name").asText());
        assertEquals(2, metadata.size());
        assertEquals(null, value.getStatusCode());
        assertEquals(null, value.getDurationMs());
        AuditLogDetail detail = AuditLogDetail.of(value, new AuditEventInterpreter());
        assertEquals(null, detail.before());
        assertEquals(null, detail.after());
        assertTrue(Boolean.TRUE.equals(request.getAttribute(
                AuditRequestContext.MEANINGFUL_EVENT_RECORDED_ATTRIBUTE)));
    }

    @Test
    void recorderDistinguishesModernLegacyAndMissingBillNumber() {
        AuditService audit = mock(AuditService.class);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        AuthUser actor = mock(AuthUser.class);
        when(actor.getId()).thenReturn(UUID.randomUUID());
        when(actor.getLoginAccount()).thenReturn("seller01");
        when(currentUser.get()).thenReturn(Optional.of(actor));
        AuditDetailViewRecorder recorder = new AuditDetailViewRecorder(audit, currentUser);

        UUID modern = UUID.randomUUID();
        recorder.record("view_sales_quote_detail", "sales_quotes", modern,
                "BJ-001", null, "销售报价单");
        verify(audit).logSuccessfulDetailView(
                actor.getId(), "seller01", "view_sales_quote_detail",
                "sales_quotes", modern, "BJ-001");

        UUID legacy = UUID.randomUUID();
        recorder.record("view_sales_quote_detail", "sales_quotes", legacy,
                "BJ-OLD", 12, "销售报价单");
        verify(audit).logSuccessfulDetailView(
                actor.getId(), "seller01", "view_sales_quote_detail_history",
                "sales_quotes", legacy, "BJ-OLD(旧系统编号 12)");

        UUID missing = UUID.randomUUID();
        recorder.record("view_sales_quote_detail", "sales_quotes", missing,
                null, null, "销售报价单");
        verify(audit).logSuccessfulDetailView(
                actor.getId(), "seller01", "view_sales_quote_detail",
                "sales_quotes", missing, "销售报价单(业务编号未记录)");

        UUID zeroLegacy = UUID.randomUUID();
        recorder.record("view_sales_quote_detail", "sales_quotes", zeroLegacy,
                "BJ-002", 0, "销售报价单");
        verify(audit).logSuccessfulDetailView(
                actor.getId(), "seller01", "view_sales_quote_detail",
                "sales_quotes", zeroLegacy, "BJ-002");
    }
}
