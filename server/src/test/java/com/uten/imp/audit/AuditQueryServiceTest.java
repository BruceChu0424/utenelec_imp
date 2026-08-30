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
import java.time.LocalDate;
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

    private static final UUID SELECTED_ACTOR =
            UUID.fromString("11111111-1111-1111-1111-111111111111");

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
        log.setResult("success;mode=custom");
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
    void listRowCarriesRedactedChineseChangeSummaryWithoutRawSnapshots() {
        AuditLog log = new AuditLog();
        log.setAction("update");
        log.setTargetType("sales_orders");
        log.setBefore("{\"status\":\"draft\"}");
        log.setAfter("{\"status\":\"approved\"}");
        log.setResult("success");

        AuditLogRow row = AuditLogRow.of(log, new AuditEventInterpreter());

        assertEquals("状态：草稿 → 已审核", row.getChangeSummary());
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
        assertMalformed(service, criteriaWithFilters("urgent", null, null, null));
        assertMalformed(service, criteriaWithFilters(null, "unknown", null, null));
        assertMalformed(service, criteriaWithFilters(null, null, "maybe", null));
        assertMalformed(service, criteriaWithFilters(null, null, null, "scheduler"));
    }

    @Test
    @SuppressWarnings("unchecked")
    void mutationOperationKindsCoverDatabaseAndHttpActions() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter(), emptyActorDirectory());
        Map<String, String> expected = Map.of(
                "create", "insert",
                "update", "update",
                "delete", "delete",
                "write", "insert/update/delete");

        expected.forEach((operationKind, directAction) -> {
            Root<AuditLog> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
            CriteriaBuilder criteriaBuilder = mock(
                    CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
            Path<String> storedAction = mock(Path.class);
            Expression<String> action = mock(Expression.class);
            when(root.<String>get("action")).thenReturn(storedAction);
            when(criteriaBuilder.lower(storedAction)).thenReturn(action);

            service.specification(criteriaWith(null, null, operationKind, null))
                    .toPredicate(root, null, criteriaBuilder);

            if ("write".equals(operationKind)) {
                verify(action).in(List.of("insert", "update", "delete"));
            } else {
                verify(criteriaBuilder, atLeastOnce()).equal(action, directAction);
            }
            verify(root, atLeastOnce()).get("httpMethod");
            verify(root).get("eventCategory");
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
    void systemActorScopeUsesNullUuidButExcludesAnonymousSecurityEvidence() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter(), emptyActorDirectory());
        Root<AuditLog> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder criteriaBuilder = mock(
                CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);

        service.specification(criteriaWith("system", null, null, null))
                .toPredicate(root, null, criteriaBuilder);

        verify(root, atLeastOnce()).get("actorId");
        verify(root, atLeastOnce()).get("eventSource");
        verify(root, atLeastOnce()).get("eventCategory");
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

        service.operationSpecification("read").toPredicate(root, null, criteriaBuilder);

        verify(criteriaBuilder).equal(action, "http_get");
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
        log.setActorId(UUID.randomUUID());
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
        assertEquals("admin(档案不可用)", payload.rows().getFirst().get("actor"));
        assertEquals("下载工资条 PDF", payload.rows().getFirst().get("actionLabel"));
        assertEquals("中", payload.rows().getFirst().get("riskLevel"));
        assertEquals("数据导出", payload.rows().getFirst().get("eventCategory"));
        assertEquals("成功", payload.rows().getFirst().get("outcome"));
        assertEquals("2026-07-31 14:00:00(北京时间)",
                payload.rows().getFirst().get("createdAt"));
        assertFalse(payload.rows().getFirst().containsKey("actionCode"));
        assertFalse(payload.rows().getFirst().containsKey("resultCode"));
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
    void outcomeFilterUsesCompositeMainCodeAndKeepsHttpFailureAuthoritative() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter(), emptyActorDirectory());
        Root<AuditLog> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);

        service.outcomeSpecification("success").toPredicate(root, null, cb);

        verify(cb).function(
                eq("split_part"),
                eq(String.class),
                any(Expression.class),
                any(Expression.class),
                any(Expression.class));
        verify(cb).greaterThanOrEqualTo(root.get("statusCode"), 400);
        verify(cb, atLeastOnce()).not(any(Predicate.class));
    }

    @Test
    void exportAcceptsSucceededCompositeCodeButHttpErrorStillWins() {
        AuditLogRepository repository = mock(AuditLogRepository.class);
        AuditQueryService service = new AuditQueryService(
                repository, new AuditEventInterpreter(), emptyActorDirectory());
        when(repository.findMaxId()).thenReturn(80L);
        AuditLog succeeded = exportRow("succeeded;mode=generated", 200);
        AuditLog httpFailed = exportRow("success;mode=custom", 500);
        when(repository.count(any(Specification.class))).thenReturn(2L);
        when(repository.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(succeeded, httpFailed)));

        ExportPayload payload = service.export(criteria(null), 100);

        assertEquals("成功", payload.rows().get(0).get("outcome"));
        assertEquals("失败", payload.rows().get(1).get("outcome"));
    }

    @Test
    void anonymousAndSystemActorPresentationIsConsistentAcrossDtosAndExport() {
        AuditLog anonymous = new AuditLog();
        anonymous.setAction("login_failed");
        anonymous.setEventSource("security");
        anonymous.setEventCategory("authentication");
        anonymous.setResult("failure");
        anonymous.setStatusCode(401);
        anonymous.setCreatedAt(OffsetDateTime.parse("2026-08-01T00:00:00Z"));

        AuditLogRow listRow = AuditLogRow.of(anonymous, new AuditEventInterpreter());
        AuditLogDetail detail = AuditLogDetail.of(anonymous, new AuditEventInterpreter());
        assertEquals("未识别访问", listRow.getActorDisplay());
        assertEquals("未识别访问", listRow.getActorType());
        assertEquals("未识别访问", detail.actorDisplay());
        assertEquals("未识别访问", detail.actorType());

        AuditLog system = new AuditLog();
        system.setActorAccount("system");
        system.setAction("audit_retention_failed");
        system.setEventSource("business");
        system.setEventCategory("system");
        assertEquals("系统任务",
                AuditLogRow.of(system, new AuditEventInterpreter()).getActorDisplay());

        AuditLogRepository repository = mock(AuditLogRepository.class);
        AuditQueryService service = new AuditQueryService(
                repository, new AuditEventInterpreter(), emptyActorDirectory());
        when(repository.findMaxId()).thenReturn(90L);
        when(repository.count(any(Specification.class))).thenReturn(1L);
        when(repository.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(anonymous)));

        ExportPayload payload = service.export(criteria(null), 100);

        assertEquals("未识别访问", payload.rows().getFirst().get("actor"));
        assertEquals("未识别访问", payload.rows().getFirst().get("actorType"));
    }

    private AuditLog exportRow(String result, int statusCode) {
        AuditLog log = new AuditLog();
        log.setAction("notice_publish");
        log.setTargetType("notices");
        log.setTargetId("测试通知");
        log.setResult(result);
        log.setEventSource("business");
        log.setStatusCode(statusCode);
        log.setCreatedAt(OffsetDateTime.parse("2026-08-01T00:00:00Z"));
        return log;
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
        AuditSummaryAggregation aggregation = mock(AuditSummaryAggregation.class);
        AuditQueryService service = new AuditQueryService(
                repository, new AuditEventInterpreter(), emptyActorDirectory(), aggregation);
        when(repository.findMaxId()).thenReturn(91L);
        AuditSummary expected = new AuditSummary(
                10, 2, 1, 3, 4,
                List.of(
                        new AuditSummary.DailyPoint(
                                LocalDate.parse("2026-08-01"), 4, 1),
                        new AuditSummary.DailyPoint(
                                LocalDate.parse("2026-08-02"), 6, 1)));
        when(aggregation.summarize(
                any(Specification.class),
                any(Specification.class),
                any(Specification.class),
                any(Specification.class),
                any(Specification.class),
                eq(LocalDate.parse("2026-08-01")),
                eq(LocalDate.parse("2026-08-02"))))
                .thenReturn(expected);

        AuditSummary summary = service.summary(criteria(null));

        assertEquals(10, summary.total());
        assertEquals(2, summary.riskCount());
        assertEquals(1, summary.criticalCount());
        assertEquals(2, summary.dailyTrend().size());
        verify(repository).findMaxId();
        verify(repository, never()).count(any(Specification.class));
        verify(aggregation).summarize(
                any(Specification.class),
                any(Specification.class),
                any(Specification.class),
                any(Specification.class),
                any(Specification.class),
                eq(LocalDate.parse("2026-08-01")),
                eq(LocalDate.parse("2026-08-02")));
    }

    @Test
    void investigationScopeRequiresUuidActorAndAtMostThirtyOneBeijingDays() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter(), emptyActorDirectory());

        assertThrows(ApiException.class, () -> service.validateInvestigationScope(
                new AuditSearchCriteria(
                        null, null, null, null, null, null,
                        null, null, null, null, null, null,
                        LocalDate.parse("2026-08-01"), LocalDate.parse("2026-08-02"),
                        null, null, true)));
        assertThrows(ApiException.class, () -> service.validateInvestigationScope(
                new AuditSearchCriteria(
                        null, null, null, null, null, null,
                        null, null, null, null, null, null,
                        LocalDate.parse("2026-08-01"), LocalDate.parse("2026-09-01"),
                        null, SELECTED_ACTOR, true)));
        service.validateInvestigationScope(criteria(null));
    }

    @Test
    void canonicalRequestIdCanReplaceActorAndDateForFocusedInvestigation() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter(), emptyActorDirectory());
        service.validateInvestigationScope(new AuditSearchCriteria(
                null, null, null, null, null, null,
                null, null, null, null,
                "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", null,
                null, null, null, null, false));
    }

    @Test
    @SuppressWarnings("unchecked")
    void activityViewUsesExactActorAndExcludesDatabaseDerivedRows() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter(), emptyActorDirectory());
        Root<AuditLog> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);

        service.specification(criteria(null)).toPredicate(root, null, cb);

        verify(cb).equal(root.get("actorId"), SELECTED_ACTOR);
        verify(cb).notEqual(any(Expression.class), eq("database"));
        verify(root, atLeastOnce()).get("httpMethod");
        verify(root, atLeastOnce()).get("httpPath");
        verify(root, atLeastOnce()).get("statusCode");
        verify(cb).lessThan(root.get("statusCode"), 400);
    }

    @Test
    @SuppressWarnings("unchecked")
    void anonymousScopeIsLimitedToIdentityFreeSecurityOrLoginEvidence() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter(), emptyActorDirectory());
        AuditSearchCriteria anonymous = new AuditSearchCriteria(
                null, null, "anonymous", null, null, null,
                null, null, null, null, null, null,
                LocalDate.parse("2026-08-01"), LocalDate.parse("2026-08-31"),
                null, null, true);
        service.validateInvestigationScope(anonymous);
        Root<AuditLog> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);

        service.specification(anonymous).toPredicate(root, null, cb);

        verify(root, atLeastOnce()).get("eventSource");
        verify(root, atLeastOnce()).get("eventCategory");
        verify(root, atLeastOnce()).get("actorId");
    }

    @Test
    void systemScopeAllowsOnlyDatedActivityFailuresAndHidesSuccess() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter(), emptyActorDirectory());
        AuditSearchCriteria system = new AuditSearchCriteria(
                null, null, "system", null, null, null,
                null, null, null, null, null, null,
                LocalDate.parse("2026-08-01"), LocalDate.parse("2026-08-31"),
                null, null, true);
        service.validateInvestigationScope(system);

        AuditLog failure = new AuditLog();
        failure.setActorAccount("system");
        failure.setAction("audit_retention_failed");
        failure.setResult("failure");
        AuditLog success = new AuditLog();
        success.setActorAccount("system");
        success.setAction("maintenance_completed");
        success.setResult("success");
        AuditLog anonymousFailure = new AuditLog();
        anonymousFailure.setAction("login_failed");
        anonymousFailure.setEventSource("security");
        anonymousFailure.setEventCategory("authentication");
        anonymousFailure.setResult("failure");
        assertTrue(AuditQueryService.isSystemExceptionRecord(failure));
        assertFalse(AuditQueryService.isSystemExceptionRecord(success));
        assertFalse(AuditQueryService.isSystemExceptionRecord(anonymousFailure));

        AuditSearchCriteria unsafe = new AuditSearchCriteria(
                null, null, "system", null, null, null,
                null, null, null, null, null, null,
                LocalDate.parse("2026-08-01"), LocalDate.parse("2026-08-31"),
                null, null, false);
        assertThrows(ApiException.class, () -> service.validateInvestigationScope(unsafe));
    }

    @Test
    void datedSystemExceptionScopeIsAcceptedByListSummaryAndExport() {
        AuditLogRepository repository = mock(AuditLogRepository.class);
        AuditSummaryAggregation aggregation = mock(AuditSummaryAggregation.class);
        AuditQueryService service = new AuditQueryService(
                repository, new AuditEventInterpreter(), emptyActorDirectory(), aggregation);
        AuditSearchCriteria system = new AuditSearchCriteria(
                null, null, "system", null, null, null,
                null, null, null, null, null, null,
                LocalDate.parse("2026-08-01"), LocalDate.parse("2026-08-31"),
                null, null, true);
        when(repository.findMaxId()).thenReturn(100L);
        when(repository.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));
        when(repository.count(any(Specification.class))).thenReturn(0L);
        when(aggregation.summarize(
                any(), any(), any(), any(), any(), any(), any()))
                .thenReturn(new AuditSummary(0, 0, 0, 0, 0, List.of()));

        assertEquals(0, service.query(system, 1, 20).getTotal());
        assertEquals(0, service.summary(system).total());
        assertEquals(0, service.export(system, 100).total());
    }

    @Test
    @SuppressWarnings("unchecked")
    void writeOperationIncludesExplicitBusinessEventsByHttpMethod() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter(), emptyActorDirectory());
        Root<AuditLog> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);

        service.operationSpecification("write").toPredicate(root, null, cb);

            verify(root, atLeastOnce()).get("httpMethod");
        verify(root).get("eventCategory");
        verify(cb).upper(any(Expression.class));
        verify(cb, atLeastOnce()).not(any(Predicate.class));
    }

    @Test
    void authenticationAndExportPostsAreExcludedFromEffectiveWriteCount() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter(), emptyActorDirectory());
        Root<AuditLog> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);

        service.operationSpecification("write").toPredicate(root, null, cb);

        verify(root).get("eventCategory");
        verify(cb, atLeastOnce()).not(any(Predicate.class));
        // Direct insert/update/delete remains an independent OR branch; custom
        // notice/task/approval events enter through the HTTP-method branch.
        verify(root).get("action");
        verify(root).get("httpMethod");
        verify(cb).like(any(Expression.class), eq("view!_%"), eq('!'));
    }

    @Test
    void explicitViewNoticeIsClassifiedAsReadAndExcludedFromWriteMethodBranch() {
        AuditQueryService service = new AuditQueryService(
                mock(AuditLogRepository.class), new AuditEventInterpreter(), emptyActorDirectory());
        Root<AuditLog> readRoot = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder readBuilder = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        service.operationSpecification("read").toPredicate(readRoot, null, readBuilder);
        verify(readBuilder).like(any(Expression.class), eq("view!_%"), eq('!'));

        Root<AuditLog> writeRoot = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder writeBuilder = mock(
                CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        service.operationSpecification("write").toPredicate(writeRoot, null, writeBuilder);
        verify(writeBuilder, atLeastOnce()).not(any(Predicate.class));
        verify(writeBuilder).like(any(Expression.class), eq("view!_%"), eq('!'));
    }

    @Test
    void exportHardCapsConfiguredLimitAtTenThousandRows() {
        AuditLogRepository repository = mock(AuditLogRepository.class);
        AuditQueryService service = new AuditQueryService(
                repository, new AuditEventInterpreter(), emptyActorDirectory());
        when(repository.findMaxId()).thenReturn(9L);
        when(repository.count(any(Specification.class))).thenReturn(10_001L);

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.export(criteria(null), 100_000));

        assertTrue(error.getMessage().contains("单次导出上限 10000 条"));
        verify(repository, never()).findAll(any(Specification.class), any(Pageable.class));
    }

    private static AuditSearchCriteria criteria(String riskLevel) {
        return new AuditSearchCriteria(
                null, null, null, riskLevel, null, null,
                null, null, null, null, null, null,
                LocalDate.parse("2026-08-01"), LocalDate.parse("2026-08-02"),
                null, SELECTED_ACTOR, true);
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

    private static AuditSearchCriteria criteriaWithFilters(
            String riskLevel,
            String eventCategory,
            String outcome,
            String eventSource) {
        return new AuditSearchCriteria(
                null, null, null, riskLevel, eventCategory, outcome,
                null, null, null, eventSource, null, null,
                LocalDate.parse("2026-08-01"), LocalDate.parse("2026-08-01"),
                null, SELECTED_ACTOR, true);
    }

    private static void assertMalformed(
            AuditQueryService service,
            AuditSearchCriteria criteria) {
        ApiException error = assertThrows(
                ApiException.class, () -> service.specification(criteria));
        assertEquals(ErrorCode.MALFORMED_REQUEST, error.getCode());
    }
}
