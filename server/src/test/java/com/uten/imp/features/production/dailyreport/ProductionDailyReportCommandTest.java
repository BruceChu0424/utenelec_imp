package com.uten.imp.features.production.dailyreport;

import com.uten.imp.application.port.ProductionQualityInspectionPort;
import com.uten.imp.application.port.ProductionFqcRecoveryPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.dailyreport.dto.DailyReportDetail;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import com.uten.imp.features.production.plan.PlanOrderItemLinkRepository;
import com.uten.imp.features.production.plan.ProductionPlanItemRepository;
import com.uten.imp.features.production.plan.ProductionPlanRepository;
import com.uten.imp.features.production.plan.ProductionProductNoAllocator;
import com.uten.imp.features.stock.StockDocumentItemRepository;
import com.uten.imp.features.stock.StockDocumentRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class ProductionDailyReportCommandTest {

    @Mock private ProductionDailyReportRepository reportRepo;
    @Mock private ProductionDailyReportItemRepository itemRepo;
    @Mock private ProductionPlanRepository planRepo;
    @Mock private ProductionPlanItemRepository planItemRepo;
    @Mock private PlanOrderItemLinkRepository linkRepo;
    @Mock private StockDocumentRepository stockDocRepo;
    @Mock private DailyReportExecutionSegmentGuard executionSegments;
    @Mock private StockDocumentItemRepository stockDocItemRepo;
    @Mock private SecurityContextCurrentUser currentUser;
    @Mock private EmployeeNameResolver nameResolver;
    @Mock private TxSessionVars tx;
    @Mock private DocNumberService docNumberService;
    @Mock private ProductionProductNoAllocator productNoAllocator;
    @Mock private EntityManager em;
    @Mock private ChainNoticeService chainNotice;
    @Mock private ProductionDocumentAccessPolicy access;
    @Mock private ProductionQualityInspectionPort qualityInspection;
    @Mock private ProductionFqcRecoveryPort fqcRecovery;
    @InjectMocks private ProductionDailyReportService service;

    @Test
    void canonicalHashNormalizesNumbersAndExcludesRetryAndReadableSnapshots() {
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID orderItemId = UUID.randomUUID();
        DailyReportSaveRequest first = request(
                "create-key-one", "SR-client-one", goodsId, unitId,
                planItemId, orderItemId, new BigDecimal("2.0"));
        DailyReportSaveRequest replay = request(
                "create-key-two", "SR-client-two", goodsId, unitId,
                planItemId, orderItemId, new BigDecimal("2.0000"));
        first.setExpectedVersion(3L);
        replay.setExpectedVersion(9L);
        first.getItems().getFirst().setPlanNo("SJ-readable-one");
        replay.getItems().getFirst().setPlanNo("SJ-readable-two");
        first.getItems().getFirst().setSalesOrderNo("XD-readable-one");
        replay.getItems().getFirst().setSalesOrderNo("XD-readable-two");
        first.getItems().getFirst().setIsFinal(null);
        replay.getItems().getFirst().setIsFinal(false);

        assertEquals(
                ProductionDailyReportService.createRequestHash(first),
                ProductionDailyReportService.createRequestHash(replay));

        replay.getItems().getFirst().setQty(new BigDecimal("2.0001"));
        assertNotEquals(
                ProductionDailyReportService.createRequestHash(first),
                ProductionDailyReportService.createRequestHash(replay));
    }

    @Test
    void canonicalHashDistinguishesRecoveryAuthorization() {
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID orderItemId = UUID.randomUUID();
        DailyReportSaveRequest first = request(
                "recovery-key-one", "SR-one", goodsId, unitId,
                planItemId, orderItemId, BigDecimal.ONE);
        DailyReportSaveRequest second = request(
                "recovery-key-two", "SR-two", goodsId, unitId,
                planItemId, orderItemId, BigDecimal.ONE);
        first.getItems().getFirst().setFqcRecoveryAuthorizationId(
                UUID.randomUUID());
        second.getItems().getFirst().setFqcRecoveryAuthorizationId(
                UUID.randomUUID());

        assertNotEquals(
                ProductionDailyReportService.createRequestHash(first),
                ProductionDailyReportService.createRequestHash(second));
    }

    @Test
    void sameActorKeyAndHashReplaysBoundReportWithoutCreatingAnother() {
        UUID actorId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        UUID reportId = UUID.randomUUID();
        DailyReportSaveRequest request = request(
                "stable-create-key", null, UUID.randomUUID(), UUID.randomUUID(),
                null, null, BigDecimal.ONE);
        String hash = ProductionDailyReportService.createRequestHash(request);
        Query advisory = query(true);
        Query command = query(false);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if (sql.contains("pg_advisory_xact_lock")) return advisory;
            if (sql.contains("FROM production_daily_report_commands")) return command;
            throw new AssertionError("unexpected SQL: " + sql);
        });
        when(command.getResultList()).thenReturn(
                java.util.Collections.singletonList(
                        new Object[]{hash, reportId}));
        when(currentUser.requireId()).thenReturn(actorId);
        ProductionDailyReport existing = new ProductionDailyReport();
        existing.setId(reportId);
        existing.setBillNo("SR20260828000001");
        existing.setBillDate(LocalDate.of(2026, 8, 28));
        existing.setMakerId(employeeId);
        existing.setStatus((short) 0);
        existing.setRowVersion(4);
        when(reportRepo.findById(reportId)).thenReturn(Optional.of(existing));
        when(itemRepo.findByReportIdOrderByLineNoAsc(reportId)).thenReturn(List.of());
        when(nameResolver.nameOf(employeeId)).thenReturn("Planner");

        DailyReportDetail replay = service.create(request);

        assertEquals(reportId, replay.getId());
        assertEquals(4, replay.getRowVersion());
        verify(reportRepo, never()).saveAndFlush(any());
        verify(itemRepo, never()).save(any());
    }

    @Test
    void sameActorKeyWithDifferentHashFailsClosed() {
        UUID actorId = UUID.randomUUID();
        DailyReportSaveRequest request = request(
                "stable-create-key", null, UUID.randomUUID(), UUID.randomUUID(),
                null, null, BigDecimal.ONE);
        Query advisory = query(true);
        Query command = query(false);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if (sql.contains("pg_advisory_xact_lock")) return advisory;
            if (sql.contains("FROM production_daily_report_commands")) return command;
            throw new AssertionError("unexpected SQL: " + sql);
        });
        when(command.getResultList()).thenReturn(
                java.util.Collections.singletonList(
                        new Object[]{"a".repeat(64), UUID.randomUUID()}));
        when(currentUser.requireId()).thenReturn(actorId);

        ApiException error = assertThrows(
                ApiException.class, () -> service.create(request));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        verify(reportRepo, never()).saveAndFlush(any());
    }

    @Test
    void staleOrMissingExpectedVersionIsRejected() {
        ApiException missing = assertThrows(
                ApiException.class,
                () -> ProductionDailyReportService.requireExpectedVersion(null, 2));
        ApiException stale = assertThrows(
                ApiException.class,
                () -> ProductionDailyReportService.requireExpectedVersion(1L, 2));

        assertEquals(ErrorCode.VALIDATION_FAILED, missing.getCode());
        assertEquals(ErrorCode.CONFLICT, stale.getCode());
        ProductionDailyReportService.requireExpectedVersion(2L, 2);
    }

    @Test
    void fullFailSourceReportCanReverseWithoutASecondContributionRollback() {
        assertFullFailReportCanReverse(false);
    }

    @Test
    void fullFailReplacementReportCanReleaseItsLotAndReverse() {
        assertFullFailReportCanReverse(true);
    }

    private void assertFullFailReportCanReverse(boolean replacement) {
        UUID reportId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID reportItemId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();

        ProductionDailyReport report = new ProductionDailyReport();
        report.setId(reportId);
        report.setBillNo("SR-FULL-FAIL-" + reportId);
        report.setBillDate(LocalDate.of(2026, 8, 28));
        report.setStatus((short) 1);
        ProductionDailyReportItem item = new ProductionDailyReportItem();
        item.setId(reportItemId);
        item.setReportId(reportId);
        item.setPlanItemId(planItemId);
        item.setGoodsId(goodsId);
        item.setUnitId(unitId);
        item.setUnitRate(BigDecimal.ONE);
        item.setQty(BigDecimal.TEN);
        if (replacement) {
            item.setFqcRecoveryAuthorizationId(UUID.randomUUID());
        }

        when(em.find(
                ProductionDailyReport.class,
                reportId,
                LockModeType.PESSIMISTIC_WRITE)).thenReturn(report);
        when(reportRepo.findById(reportId)).thenReturn(Optional.of(report));
        when(itemRepo.findByReportIdOrderByLineNoAsc(reportId))
                .thenReturn(List.of(item));
        when(linkRepo.findActiveByPlanItemIds(any())).thenReturn(List.of());
        when(fqcRecovery.effectiveContribution(reportItemId, BigDecimal.TEN))
                .thenReturn(BigDecimal.ZERO);
        when(reportRepo.saveAndFlush(report)).thenReturn(report);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            Query query = query(false);
            if (sql.contains("SELECT id")
                    && sql.contains("FROM production_plan_items")
                    && !sql.contains("JOIN production_plans")) {
                when(query.getResultList()).thenReturn(List.of(planItemId));
            } else if (sql.contains("SELECT i.id, i.plan_id")) {
                when(query.getResultList()).thenReturn(
                        java.util.Collections.singletonList(new Object[]{
                        planItemId, planId, BigDecimal.TEN, BigDecimal.ZERO,
                        goodsId, null, unitId, null, null, "SJ-FULL-FAIL",
                        BigDecimal.ONE, BigDecimal.ZERO
                        }));
            } else if (sql.contains("FROM stock_documents")) {
                when(query.getResultList()).thenReturn(List.of());
            } else if (sql.contains("FROM production_plans")
                    && sql.contains("source_daily_report_id")) {
                when(query.getResultList()).thenReturn(List.of());
            }
            return query;
        });

        DailyReportDetail detail = service.reverse(reportId);

        assertEquals((short) -1, report.getStatus());
        assertEquals(reportId, detail.getId());
        verify(fqcRecovery).reverseReportEffects(reportId);
        verify(qualityInspection).cancelForReversedReport(reportId);
        verify(em, never()).createNativeQuery(argThat(
                sql -> sql.contains("SET fqty = COALESCE(fqty,0) - :q")));
        verify(linkRepo, never()).save(any());
    }

    private Query query(boolean scalar) {
        Query query = org.mockito.Mockito.mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        if (scalar) {
            when(query.getSingleResult()).thenReturn(1L);
        }
        return query;
    }

    private static DailyReportSaveRequest request(
            String key,
            String billNo,
            UUID goodsId,
            UUID unitId,
            UUID planItemId,
            UUID orderItemId,
            BigDecimal qty) {
        DailyReportSaveRequest request = new DailyReportSaveRequest();
        request.setIdempotencyKey(key);
        request.setBillNo(billNo);
        request.setBillDate(LocalDate.of(2026, 8, 28));
        DailyReportItemLine line = new DailyReportItemLine();
        line.setGoodsId(goodsId);
        line.setUnitId(unitId);
        line.setUnitRate(new BigDecimal("1.000000"));
        line.setQty(qty);
        line.setPlanItemId(planItemId);
        line.setSalesOrderItemId(orderItemId);
        request.setItems(List.of(line));
        return request;
    }
}
