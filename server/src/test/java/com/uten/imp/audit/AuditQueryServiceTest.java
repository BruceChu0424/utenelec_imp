package com.uten.imp.audit;

import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Expression;
import jakarta.persistence.criteria.Path;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import org.junit.jupiter.api.Test;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.nullable;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class AuditQueryServiceTest {

    @Test
    void detailExposesRedactedBeforeAndAfterForSystemManagement() {
        AuditLogRepository repository = mock(AuditLogRepository.class);
        AuditQueryService service = new AuditQueryService(
                repository, new AuditEventInterpreter());
        AuditLog log = new AuditLog();
        log.setId(42L);
        log.setActorId(UUID.randomUUID());
        log.setActorAccount("planner");
        log.setAction("update");
        log.setTargetType("production_execution_segments");
        log.setTargetId(UUID.randomUUID().toString());
        log.setBefore("{\"status\":\"READY\"}");
        log.setAfter("{\"status\":\"DISPATCHED\"}");
        log.setIp("127.0.0.1");
        log.setUserAgent("test");
        log.setResult("success");
        log.setCreatedAt(OffsetDateTime.parse("2026-07-31T06:00:00+08:00"));
        when(repository.findById(42L)).thenReturn(Optional.of(log));

        AuditLogDetail detail = service.detail(42L);

        assertEquals(42L, detail.id());
        assertEquals("planner", detail.actorAccount());
        assertEquals(
                "production_execution_segments", detail.targetType());
        assertEquals("{\"status\":\"READY\"}", detail.before());
        assertEquals("{\"status\":\"DISPATCHED\"}", detail.after());
        assertEquals("test", detail.userAgent());
    }

    @Test
    void detailFailsClosedWhenRowWasNeverPresentOrHasBeenArchived() {
        AuditLogRepository repository = mock(AuditLogRepository.class);
        AuditQueryService service = new AuditQueryService(
                repository, new AuditEventInterpreter());
        when(repository.findById(99L)).thenReturn(Optional.empty());

        ApiException error = assertThrows(
                ApiException.class, () -> service.detail(99L));

        assertEquals("审计日志不存在或已归档", error.getMessage());
    }

    @Test
    @SuppressWarnings("unchecked")
    void exportUsesReadableForensicColumnsAndExcludesRawSnapshots() {
        AuditLogRepository repository = mock(AuditLogRepository.class);
        AuditQueryService service = new AuditQueryService(
                repository, new AuditEventInterpreter());
        AuditLog log = new AuditLog();
        log.setId(7L);
        log.setActorAccount("admin");
        log.setAction("download_payroll_slip");
        log.setTargetType("payroll_slips");
        log.setTargetId(UUID.randomUUID().toString());
        log.setBefore("{secret:must-not-export}");
        log.setAfter("{secret:must-not-export}");
        log.setResult("success");
        log.setEventSource("business");
        log.setHttpMethod("POST");
        log.setHttpPath("/api/payroll/slips/ignored/download");
        log.setStatusCode(200);
        log.setDurationMs(18L);
        log.setRiskLevel("low");
        log.setEventCategory("business");
        log.setCreatedAt(OffsetDateTime.parse("2026-07-31T06:00:00Z"));
        when(repository.count(any(Specification.class))).thenReturn(1L);
        when(repository.findAll(
                any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(log)));

        ExportPayload payload = service.export(
                null, null, "risky", null, null, null, null, 100);

        assertEquals(1, payload.total());
        assertEquals("admin", payload.rows().getFirst().get("actor"));
        assertEquals("下载工资条 PDF", payload.rows().getFirst().get("actionLabel"));
        assertEquals("中", payload.rows().getFirst().get("riskLevel"));
        assertEquals("数据导出", payload.rows().getFirst().get("eventCategory"));
        assertFalse(payload.rows().getFirst().containsKey("before"));
        assertFalse(payload.rows().getFirst().containsKey("after"));
    }

    @Test
    @SuppressWarnings("unchecked")
    void exportRejectsTheRequestBeforeLoadingRowsWhenOverConfiguredLimit() {
        AuditLogRepository repository = mock(AuditLogRepository.class);
        AuditQueryService service = new AuditQueryService(
                repository, new AuditEventInterpreter());
        when(repository.count(any(Specification.class))).thenReturn(101L);

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.export(
                        null, null, null, null, null, null, null, 100));

        assertTrue(error.getMessage().contains("超过单次导出上限 100 条"));
        verify(repository, never()).findAll(
                any(Specification.class), any(Pageable.class));
    }

    @Test
    @SuppressWarnings("unchecked")
    void riskFiltersPromoteForcedMediumActionsAndRemoveThemFromLowRisk() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter());
        Root<AuditLog> root = mock(Root.class);
        CriteriaBuilder criteria = mock(CriteriaBuilder.class);
        Path<String> storedRisk = mock(Path.class);
        Path<String> storedAction = mock(Path.class);
        Expression<String> action = mock(Expression.class);
        Predicate storedLow = mock(Predicate.class);
        Predicate storedMedium = mock(Predicate.class);
        Predicate sensitiveAction = mock(Predicate.class);
        Predicate promoted = mock(Predicate.class);
        Predicate effectiveMedium = mock(Predicate.class);
        Predicate notSensitive = mock(Predicate.class);
        Predicate effectiveLow = mock(Predicate.class);

        when(root.<String>get("riskLevel")).thenReturn(storedRisk);
        when(root.<String>get("action")).thenReturn(storedAction);
        when(criteria.lower(storedAction)).thenReturn(action);
        when(criteria.equal(storedRisk, "low")).thenReturn(storedLow);
        when(criteria.equal(storedRisk, "medium")).thenReturn(storedMedium);
        when(action.in(List.of(
                "view_audit_log_detail",
                "verify_local_audit_receipt",
                "download_payroll_slip")))
                .thenReturn(sensitiveAction);
        when(criteria.and(storedLow, sensitiveAction)).thenReturn(promoted);
        when(criteria.or(storedMedium, promoted)).thenReturn(effectiveMedium);
        when(criteria.not(sensitiveAction)).thenReturn(notSensitive);
        when(criteria.and(storedLow, notSensitive)).thenReturn(effectiveLow);

        assertSame(
                effectiveMedium,
                service.riskSpecification("medium").toPredicate(root, null, criteria));
        assertSame(
                effectiveLow,
                service.riskSpecification("low").toPredicate(root, null, criteria));
    }

    @Test
    @SuppressWarnings("unchecked")
    void categoryFiltersApplySecurityAndPayrollExportOverrides() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter());
        Root<AuditLog> root = mock(Root.class);
        CriteriaBuilder criteria = mock(CriteriaBuilder.class);
        Path<String> storedCategory = mock(Path.class);
        Path<String> storedAction = mock(Path.class);
        Expression<String> action = mock(Expression.class);
        Predicate storedSecurity = mock(Predicate.class);
        Predicate storedExport = mock(Predicate.class);
        Predicate forcedSecurity = mock(Predicate.class);
        Predicate forcedExport = mock(Predicate.class);
        Predicate anyForcedCategory = mock(Predicate.class);
        Predicate notForcedCategory = mock(Predicate.class);
        Predicate storedSecurityUnforced = mock(Predicate.class);
        Predicate storedExportUnforced = mock(Predicate.class);
        Predicate expectedSecurity = mock(Predicate.class);
        Predicate expectedExport = mock(Predicate.class);

        when(root.<String>get("eventCategory")).thenReturn(storedCategory);
        when(root.<String>get("action")).thenReturn(storedAction);
        when(criteria.lower(storedAction)).thenReturn(action);
        when(criteria.equal(storedCategory, "security")).thenReturn(storedSecurity);
        when(action.in(List.of(
                "view_audit_log_list",
                "view_audit_log_summary",
                "view_audit_log_detail",
                "verify_local_audit_receipt")))
                .thenReturn(forcedSecurity);
        when(action.in(List.of("download_payroll_slip")))
                .thenReturn(forcedExport);
        when(criteria.or(forcedSecurity, forcedExport))
                .thenReturn(anyForcedCategory);
        when(criteria.not(anyForcedCategory)).thenReturn(notForcedCategory);
        when(criteria.and(storedSecurity, notForcedCategory))
                .thenReturn(storedSecurityUnforced);
        when(criteria.or(forcedSecurity, storedSecurityUnforced))
                .thenReturn(expectedSecurity);

        assertSame(
                expectedSecurity,
                service.categorySpecification("security").toPredicate(root, null, criteria));

        when(criteria.equal(storedCategory, "export")).thenReturn(storedExport);
        when(criteria.and(storedExport, notForcedCategory))
                .thenReturn(storedExportUnforced);
        when(criteria.or(forcedExport, storedExportUnforced))
                .thenReturn(expectedExport);

        assertSame(
                expectedExport,
                service.categorySpecification("export").toPredicate(root, null, criteria));
    }

    @Test
    @SuppressWarnings("unchecked")
    void summaryReturnsEffectiveRiskCountsAndNativeTrendCoversSensitiveActions()
            throws Exception {
        AuditLogRepository repository = mock(AuditLogRepository.class);
        AuditQueryService service = new AuditQueryService(
                repository, new AuditEventInterpreter());
        when(repository.count(any(Specification.class)))
                .thenReturn(10L, 2L, 1L, 3L, 4L);
        when(repository.summarizeDaily(
                any(OffsetDateTime.class),
                any(OffsetDateTime.class),
                nullable(String.class),
                nullable(String.class),
                nullable(String.class)))
                .thenReturn(java.util.Collections.singletonList(
                        new Object[]{BusinessTime.today(), 5L, 2L}));

        AuditSummary summary = service.summary(null, null, null, null, null);

        assertEquals(10, summary.total());
        assertEquals(2, summary.riskCount());
        assertEquals(1, summary.criticalCount());
        assertEquals(2, summary.dailyTrend().getLast().riskCount());

        var method = AuditLogRepository.class.getDeclaredMethod(
                "summarizeDaily",
                OffsetDateTime.class,
                OffsetDateTime.class,
                String.class,
                String.class,
                String.class);
        String sql = method.getAnnotation(
                org.springframework.data.jpa.repository.Query.class).value();
        assertTrue(sql.contains("view_audit_log_detail"));
        assertTrue(sql.contains("verify_local_audit_receipt"));
        assertTrue(sql.contains("download_payroll_slip"));
        assertTrue(sql.contains("THEN 'export'"));
    }
}
