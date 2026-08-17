package com.uten.imp.audit;

import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Expression;
import jakarta.persistence.criteria.Path;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import org.junit.jupiter.api.Test;
import org.hibernate.query.criteria.JpaExpression;
import org.mockito.ArgumentCaptor;
import org.mockito.Answers;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.withSettings;

class AuditQueryServiceTest {

    private static AuditActorDirectory emptyActorDirectory() {
        AuditActorDirectory directory = mock(AuditActorDirectory.class);
        when(directory.resolve(any(), any()))
                .thenReturn(AuditActorDirectory.Resolution.empty());
        when(directory.findUserIdsByNameKeyword(any()))
                .thenReturn(java.util.Set.of());
        return directory;
    }

    @Test
    void detailExposesRedactedBeforeAndAfterForSystemManagement() {
        AuditLogRepository repository = mock(AuditLogRepository.class);
        AuditQueryService service = new AuditQueryService(
                repository, new AuditEventInterpreter(), emptyActorDirectory());
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
                repository, new AuditEventInterpreter(), emptyActorDirectory());
        when(repository.findById(99L)).thenReturn(Optional.empty());

        ApiException error = assertThrows(
                ApiException.class, () -> service.detail(99L));

        assertEquals("审计日志不存在或已归档", error.getMessage());
    }

    @Test
    @SuppressWarnings("unchecked")
    void listCapturesAHighWaterBoundaryAndUsesDeterministicDescendingSort() {
        AuditLogRepository repository = mock(AuditLogRepository.class);
        AuditQueryService service = new AuditQueryService(
                repository, new AuditEventInterpreter(), emptyActorDirectory());
        when(repository.findMaxId()).thenReturn(61L);
        when(repository.findAll(
                any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));

        AuditPageResponse response = service.query(criteria(null), 0, 1_000);

        assertEquals(61L, response.getSnapshotId());
        assertEquals(1, response.getPage());
        assertEquals(100, response.getSize());
        ArgumentCaptor<Specification<AuditLog>> specificationCaptor =
                ArgumentCaptor.forClass(Specification.class);
        ArgumentCaptor<Pageable> pageableCaptor = ArgumentCaptor.forClass(Pageable.class);
        verify(repository).findAll(specificationCaptor.capture(), pageableCaptor.capture());
        Pageable pageable = pageableCaptor.getValue();
        assertEquals(
                org.springframework.data.domain.Sort.Direction.DESC,
                pageable.getSort().getOrderFor("createdAt").getDirection());
        assertEquals(
                org.springframework.data.domain.Sort.Direction.DESC,
                pageable.getSort().getOrderFor("id").getDirection());

        Root<AuditLog> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder criteriaBuilder = mock(
                CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        specificationCaptor.getValue().toPredicate(root, null, criteriaBuilder);
        verify(criteriaBuilder).lessThanOrEqualTo(root.get("id"), 61L);
    }

    @Test
    @SuppressWarnings("unchecked")
    void suppliedSnapshotIsReusedWithoutAdvancingTheHighWaterMark() {
        AuditLogRepository repository = mock(AuditLogRepository.class);
        AuditQueryService service = new AuditQueryService(
                repository, new AuditEventInterpreter(), emptyActorDirectory());
        when(repository.findAll(
                any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));

        AuditPageResponse response = service.query(
                criteria(null).withSnapshotId(0), 1, 20);

        assertEquals(0L, response.getSnapshotId());
        verify(repository, never()).findMaxId();
    }

    @Test
    @SuppressWarnings("unchecked")
    void searchableFiltersUseOnlyTheApprovedNonSensitiveColumns() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter(), emptyActorDirectory());
        String requestId = "11111111-2222-3333-4444-555555555555";
        AuditSearchCriteria filters = new AuditSearchCriteria(
                "up", "alice", "user", null, null, null,
                "HP0001", "goods", "HP0001", "database", requestId, "write",
                null, null, 99L);
        Root<AuditLog> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder criteriaBuilder = mock(
                CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        Path<UUID> requestIdPath = mock(
                Path.class, withSettings().extraInterfaces(JpaExpression.class));
        JpaExpression<String> requestIdText = mock(JpaExpression.class);
        when(root.<UUID>get("requestId")).thenReturn(requestIdPath);
        when(((JpaExpression<?>) requestIdPath).cast(String.class))
                .thenReturn(requestIdText);

        service.specification(filters).toPredicate(root, null, criteriaBuilder);

        verify(root, atLeastOnce()).get("action");
        verify(root, atLeastOnce()).get("actorAccount");
        verify(root, atLeastOnce()).get("targetType");
        verify(root, atLeastOnce()).get("targetId");
        verify(root, atLeastOnce()).get("eventSource");
        verify(root, atLeastOnce()).get("httpPath");
        verify(root, atLeastOnce()).get("requestId");
        verify(root, atLeastOnce()).get("id");
        verify((JpaExpression<?>) requestIdPath).cast(String.class);
        verify(root, never()).get("before");
        verify(root, never()).get("after");
        verify(root, never()).get("userAgent");
        verify(root, never()).get("ip");
    }

    @Test
    @SuppressWarnings("unchecked")
    void shortcutTargetsIncludeTheirRequestRouteGroups() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter(), emptyActorDirectory());
        Map<String, String> routes = Map.of(
                "goods", "api/master/goods",
                "material_categories", "api/master/material-categories",
                "clients", "api/master/clients",
                "suppliers", "api/master/suppliers");

        routes.forEach((targetType, routeGroup) -> {
            Root<AuditLog> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
            CriteriaBuilder criteriaBuilder = mock(
                    CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
            Path<String> storedTarget = mock(Path.class);
            Expression<String> normalizedTarget = mock(Expression.class);
            when(root.<String>get("targetType")).thenReturn(storedTarget);
            when(criteriaBuilder.lower(storedTarget)).thenReturn(normalizedTarget);

            AuditSearchCriteria filters = new AuditSearchCriteria(
                    null, null, null, null, null, null,
                    null, targetType, null, null, null, null,
                    null, null, null);
            service.specification(filters).toPredicate(root, null, criteriaBuilder);

            verify(normalizedTarget).in(List.of(targetType, routeGroup));
        });
    }

    @Test
    void rejectsInvalidAuditFilterEnumsIdsAndNegativeSnapshots() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter(), emptyActorDirectory());

        assertMalformed(service, criteriaWith(null, null, "execute", null));
        assertMalformed(service, criteriaWith("employee", null, null, null));
        assertMalformed(service, criteriaWith(null, "not-a-uuid", null, null));
        assertMalformed(service, criteriaWith(null, null, null, -1L));
    }

    @Test
    @SuppressWarnings("unchecked")
    void mutationOperationKindsCoverDatabaseAndHttpActions() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter(), emptyActorDirectory());
        Map<String, List<String>> expected = Map.of(
                "create", List.of("insert", "http_post"),
                "update", List.of("update", "http_put", "http_patch"),
                "delete", List.of("delete", "http_delete"),
                "write", List.of(
                        "insert", "update", "delete",
                        "http_post", "http_put", "http_patch", "http_delete"));

        expected.forEach((operationKind, actions) -> {
            Root<AuditLog> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
            CriteriaBuilder criteriaBuilder = mock(
                    CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
            Path<String> storedAction = mock(Path.class);
            Expression<String> action = mock(Expression.class);
            when(root.<String>get("action")).thenReturn(storedAction);
            when(criteriaBuilder.lower(storedAction)).thenReturn(action);
            when(action.in(actions)).thenReturn(mock(Predicate.class));

            service.specification(criteriaWith(null, null, operationKind, null))
                    .toPredicate(root, null, criteriaBuilder);

            verify(action).in(actions);
        });
    }

    @Test
    @SuppressWarnings("unchecked")
    void deleteAndUpdateFiltersRecognizeHistoricalSoftDeleteSnapshots() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter(), emptyActorDirectory());

        for (String operationKind : List.of("delete", "update")) {
            Root<AuditLog> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
            CriteriaBuilder criteriaBuilder = mock(
                    CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);

            service.specification(criteriaWith(null, null, operationKind, null))
                    .toPredicate(root, null, criteriaBuilder);

            verify(root, atLeastOnce()).get("before");
            verify(root, atLeastOnce()).get("after");
            verify(criteriaBuilder, times(4)).function(
                    eq("jsonb_extract_path_text"),
                    eq(String.class),
                    any(Expression.class),
                    any(Expression.class));
            verify(criteriaBuilder, times(2)).function(
                    eq("jsonb_exists"),
                    eq(Boolean.class),
                    any(Expression.class),
                    any(Expression.class));
        }
    }

    @Test
    @SuppressWarnings("unchecked")
    void systemActorScopeRequiresBothActorIdentityFieldsToBeEmpty() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter(), emptyActorDirectory());
        Root<AuditLog> root = mock(Root.class);
        CriteriaBuilder criteriaBuilder = mock(CriteriaBuilder.class);
        Path<UUID> actorId = mock(Path.class);
        Path<String> actorAccount = mock(Path.class);
        Expression<String> trimmedAccount = mock(Expression.class);
        when(root.<UUID>get("actorId")).thenReturn(actorId);
        when(root.<String>get("actorAccount")).thenReturn(actorAccount);
        when(criteriaBuilder.trim(actorAccount)).thenReturn(trimmedAccount);

        service.specification(criteriaWith("system", null, null, null))
                .toPredicate(root, null, criteriaBuilder);

        verify(criteriaBuilder).isNull(actorId);
        verify(criteriaBuilder).isNull(actorAccount);
        verify(criteriaBuilder).equal(trimmedAccount, "");
    }

    @Test
    @SuppressWarnings("unchecked")
    void readOperationIncludesHttpGetsAndExplicitViewEvents() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter(), emptyActorDirectory());
        Root<AuditLog> root = mock(Root.class);
        CriteriaBuilder criteriaBuilder = mock(CriteriaBuilder.class);
        Path<String> storedAction = mock(Path.class);
        Expression<String> action = mock(Expression.class);
        Predicate httpGet = mock(Predicate.class);
        when(root.<String>get("action")).thenReturn(storedAction);
        when(criteriaBuilder.lower(storedAction)).thenReturn(action);
        when(action.in(List.of("http_get"))).thenReturn(httpGet);

        service.specification(criteriaWith(null, null, "read", null))
                .toPredicate(root, null, criteriaBuilder);

        verify(action).in(List.of("http_get"));
        verify(criteriaBuilder).like(action, "view!_%", '!');
    }

    @Test
    @SuppressWarnings("unchecked")
    void exportUsesReadableForensicColumnsAndExcludesRawSnapshots() {
        AuditLogRepository repository = mock(AuditLogRepository.class);
        AuditQueryService service = new AuditQueryService(
                repository, new AuditEventInterpreter(), emptyActorDirectory());
        when(repository.findMaxId()).thenReturn(73L);
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

        ExportPayload payload = service.export(criteria(null), 100);

        assertEquals(1, payload.total());
        assertEquals("admin", payload.rows().getFirst().get("actor"));
        assertEquals("下载工资条 PDF", payload.rows().getFirst().get("actionLabel"));
        assertEquals("中", payload.rows().getFirst().get("riskLevel"));
        assertEquals("数据导出", payload.rows().getFirst().get("eventCategory"));
        assertFalse(payload.rows().getFirst().containsKey("before"));
        assertFalse(payload.rows().getFirst().containsKey("after"));
        verify(repository).findMaxId();

        ArgumentCaptor<Specification<AuditLog>> specificationCaptor =
                ArgumentCaptor.forClass(Specification.class);
        verify(repository).count(specificationCaptor.capture());
        Root<AuditLog> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder criteriaBuilder = mock(
                CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        specificationCaptor.getValue().toPredicate(root, null, criteriaBuilder);
        verify(criteriaBuilder).lessThanOrEqualTo(root.get("id"), 73L);
    }

    @Test
    @SuppressWarnings("unchecked")
    void exportRejectsTheRequestBeforeLoadingRowsWhenOverConfiguredLimit() {
        AuditLogRepository repository = mock(AuditLogRepository.class);
        AuditQueryService service = new AuditQueryService(
                repository, new AuditEventInterpreter(), emptyActorDirectory());
        when(repository.count(any(Specification.class))).thenReturn(101L);

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.export(criteria(null), 100));

        assertTrue(error.getMessage().contains("超过单次导出上限 100 条"));
        verify(repository, never()).findAll(
                any(Specification.class), any(Pageable.class));
    }

    @Test
    @SuppressWarnings("unchecked")
    void riskFiltersPromoteForcedMediumActionsAndRemoveThemFromLowRisk() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter(), emptyActorDirectory());
        Root<AuditLog> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder criteria = mock(
                CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        Path<String> storedRisk = mock(Path.class);
        Path<String> storedAction = mock(Path.class);
        Expression<String> action = mock(Expression.class);
        Predicate storedLow = mock(Predicate.class);
        Predicate storedMedium = mock(Predicate.class);
        Predicate sensitiveAction = mock(Predicate.class);
        Predicate promoted = mock(Predicate.class);
        Predicate effectiveMedium = mock(Predicate.class);
        Predicate notSensitive = mock(Predicate.class);

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

        service.riskSpecification("medium").toPredicate(root, null, criteria);
        verify(criteria).or(storedMedium, promoted);
        service.riskSpecification("low").toPredicate(root, null, criteria);
        verify(criteria).not(sensitiveAction);
        verify(root, atLeastOnce()).get("before");
        verify(root, atLeastOnce()).get("after");
    }

    @Test
    @SuppressWarnings("unchecked")
    void highAndRiskyFiltersIncludeHistoricalSoftDeletes() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter(), emptyActorDirectory());

        for (String riskLevel : List.of("high", "risky")) {
            Root<AuditLog> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
            CriteriaBuilder criteria = mock(
                    CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);

            service.riskSpecification(riskLevel).toPredicate(root, null, criteria);

            verify(root, atLeastOnce()).get("before");
            verify(root, atLeastOnce()).get("after");
        }
    }

    @Test
    @SuppressWarnings("unchecked")
    void mediumAndCriticalFiltersExcludeHistoricalSoftDeletes() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter(), emptyActorDirectory());

        for (String riskLevel : List.of("medium", "critical")) {
            Root<AuditLog> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
            CriteriaBuilder criteria = mock(
                    CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);

            service.riskSpecification(riskLevel).toPredicate(root, null, criteria);

            verify(criteria, atLeastOnce()).not(any(Predicate.class));
            verify(root, atLeastOnce()).get("before");
            verify(root, atLeastOnce()).get("after");
        }
    }

    @Test
    @SuppressWarnings("unchecked")
    void categoryFiltersApplySecurityAndPayrollExportOverrides() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter(), emptyActorDirectory());
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
    void summaryReturnsEffectiveRiskCountsAndBuildsTrendFromTheSameSpecification() {
        AuditLogRepository repository = mock(AuditLogRepository.class);
        AuditQueryService service = new AuditQueryService(
                repository, new AuditEventInterpreter(), emptyActorDirectory());
        when(repository.findMaxId()).thenReturn(91L);
        when(repository.count(any(Specification.class)))
                .thenReturn(10L, 2L, 1L, 3L, 4L);

        AuditSummary summary = service.summary(criteria(null));

        assertEquals(10, summary.total());
        assertEquals(2, summary.riskCount());
        assertEquals(1, summary.criticalCount());
        assertEquals(7, summary.dailyTrend().size());
        verify(repository).findMaxId();
    }

    private static AuditSearchCriteria criteria(String riskLevel) {
        return new AuditSearchCriteria(
                null, null, null, riskLevel, null, null,
                null, null, null, null, null, null,
                null, null, null);
    }

    private static AuditSearchCriteria criteriaWith(
            String actorScope,
            String requestId,
            String operationKind,
            Long snapshotId) {
        return new AuditSearchCriteria(
                null, null, actorScope, null, null, null,
                null, null, null, null, requestId, operationKind,
                null, null, snapshotId);
    }

    private static void assertMalformed(
            AuditQueryService service,
            AuditSearchCriteria criteria) {
        ApiException error = assertThrows(
                ApiException.class, () -> service.specification(criteria));
        assertEquals(ErrorCode.MALFORMED_REQUEST, error.getCode());
    }
}
