package com.uten.imp.features.production.execution;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.features.production.fulfillment.ProductionExecutionReadinessService;
import com.uten.imp.features.production.mrp.ProductionGoodsWorkshopPreferenceService;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class ProductionExecutionSegmentServiceTest {

    private final UUID planId = UUID.randomUUID();
    private final UUID segmentId = UUID.randomUUID();
    private final UUID packageId = UUID.randomUUID();
    private EntityManager em;
    private final UUID goodsId = UUID.randomUUID();
    private SecurityContextCurrentUser currentUser;
    private ProductionGoodsWorkshopPreferenceService workshopPreferences;
    private ProductionExecutionReadinessService readiness;
    private ProductionAssignmentValidator assignmentValidator;
    private ProductionExecutionSegmentService service;

    @BeforeEach
    void setUp() {
        em = mock(EntityManager.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        workshopPreferences = mock(ProductionGoodsWorkshopPreferenceService.class);
        readiness = mock(ProductionExecutionReadinessService.class);
        assignmentValidator = mock(ProductionAssignmentValidator.class);
        service = new ProductionExecutionSegmentService(
                em,
                workshopPreferences,
                readiness,
                assignmentValidator,
                currentUser,
                mock(TxSessionVars.class),
                mock(ChainNoticeService.class));
    }

    @Test
    void staleExpectedVersionIsRejectedBeforeMutation() {
        stubLockAndReplay("READY", 7L, "CONFIRMED");

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.dispatch(
                        planId,
                        segmentId,
                        new SegmentTransitionRequest(6L, "dispatch-key-0001")));

        assertTrue(error.getMessage().contains("其他用户修改"));
    }

    @Test
    void illegalStatusTransitionIsRejected() {
        stubLockAndReplay("WAITING", 3L, "CONFIRMED");

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.dispatch(
                        planId,
                        segmentId,
                        new SegmentTransitionRequest(3L, "dispatch-key-0002")));

        assertTrue(error.getMessage().contains("状态已经变化"));
    }

    @Test
    void explicitDeferReleaseRechecksKitAndRecordsFinalVersion() {
        UUID warehouseId = UUID.randomUUID();
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        when(readiness.lockManualReleaseDimensions(planId, segmentId))
                .thenReturn(warehouseId);
        Query lock = locked(
                "WAITING", 5L, "CONFIRMED", null, false);
        Query replay = query();
        when(replay.getResultList()).thenReturn(List.of());
        Query update = query();
        when(update.executeUpdate()).thenReturn(1);
        Query view = query();
        when(view.getResultList()).thenReturn(
                Collections.singletonList(viewRow(null, 7L)));
        Query event = query();
        when(event.executeUpdate()).thenReturn(1);
        when(em.createNativeQuery(anyString())).thenReturn(
                lock, replay, update, view, event);

        ExecutionSegmentView result = service.releaseDefer(
                planId,
                segmentId,
                new SegmentTransitionRequest(
                        5L, "release-defer-key-0001"));

        assertTrue(result.autoPromoteWhenReady());
        verify(readiness).promoteAfterManualRelease(
                segmentId, warehouseId);
        verify(event).setParameter("resultingVersion", 7L);
    }

    @Test
    void confirmedPackageCannotCancelOneSegment() {
        stubLockAndReplay("READY", 2L, "CONFIRMED");

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.cancel(
                        planId,
                        segmentId,
                        new SegmentTransitionRequest(2L, "cancel-key-00001")));

        assertTrue(error.getMessage().contains("整包取消"));
    }

    @Test
    void successfulAssignmentLearnsWorkshopSelection() {
        UUID workshopId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        when(currentUser.requireEmployeeId()).thenReturn(employeeId);
        Query lock = locked("READY", 1L, "CONFIRMED");
        Query replay = query();
        when(replay.getResultList()).thenReturn(List.of());
        Query update = query();
        when(update.executeUpdate()).thenReturn(1);
        Query event = query();
        when(event.executeUpdate()).thenReturn(1);
        Query view = query();
        when(view.getResultList()).thenReturn(
                Collections.singletonList(viewRow(workshopId, 2L)));
        when(em.createNativeQuery(anyString())).thenReturn(
                lock, replay, update, event, view);

        service.assign(planId, segmentId, new SegmentAssignmentRequest(
                1L, "assign-key-0001", workshopId, null, null, null, null));

        verify(workshopPreferences).learnSelection(
                goodsId, workshopId, employeeId);
    }

    @Test
    void unchangedWorkshopAssignmentDoesNotLearnAgain() {
        UUID workshopId = UUID.randomUUID();
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        Query lock = locked("READY", 1L, "CONFIRMED", workshopId);
        Query replay = query();
        when(replay.getResultList()).thenReturn(List.of());
        Query update = query();
        when(update.executeUpdate()).thenReturn(1);
        Query event = query();
        when(event.executeUpdate()).thenReturn(1);
        Query view = query();
        when(view.getResultList()).thenReturn(
                Collections.singletonList(viewRow(workshopId, 2L)));
        when(em.createNativeQuery(anyString())).thenReturn(
                lock, replay, update, event, view);

        service.assign(planId, segmentId, new SegmentAssignmentRequest(
                1L, "assign-key-0003", workshopId, null, null, null, null));

        verifyNoInteractions(workshopPreferences);
    }

    @Test
    void assignmentReplayDoesNotLearnWorkshopAgain() {
        UUID workshopId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        SegmentAssignmentRequest request = new SegmentAssignmentRequest(
                1L, "assign-key-0002", workshopId, null, null, null, null);
        Query lock = locked("READY", 2L, "CONFIRMED");
        Query replay = query();
        String hash = PlanningPackageFingerprint.sha256(List.of(
                "VERSION|1",
                "WORKSHOP|" + workshopId,
                "TEAM|",
                "OWNER|",
                "BEGIN|",
                "END|"));
        when(replay.getResultList()).thenReturn(
                Collections.singletonList(new Object[]{hash, 2L}));
        Query view = query();
        when(view.getResultList()).thenReturn(
                Collections.singletonList(viewRow(workshopId, 2L)));
        when(em.createNativeQuery(anyString())).thenReturn(lock, replay, view);

        service.assign(planId, segmentId, request);

        verify(workshopPreferences, never()).learnSelection(
                goodsId, workshopId, employeeId);
    }


    private Query locked(
            String status, long version, String packageStatus) {
        return locked(status, version, packageStatus, null, true);
    }

    private Query locked(
            String status, long version, String packageStatus,
            UUID workshopId) {
        return locked(status, version, packageStatus, workshopId, true);
    }

    private Query locked(
            String status, long version, String packageStatus,
            UUID workshopId, boolean autoPromoteWhenReady) {
        Query lock = query();
        when(lock.getResultList()).thenReturn(
                Collections.singletonList(new Object[]{
                        segmentId,
                        planId,
                        packageId,
                        status,
                        version,
                        packageStatus,
                        (short) 1,
                        false,
                        false,
                        false,
                        goodsId,
                        workshopId,
                        autoPromoteWhenReady
                }));
        return lock;
    }

    private Object[] viewRow(UUID workshopId, long version) {
        return new Object[]{
                segmentId, packageId, planId, UUID.randomUUID(),
                1, "SEG-1", goodsId, "G-1", "Goods",
                null, UUID.randomUUID(),
                BigDecimal.ONE, BigDecimal.ZERO, BigDecimal.ONE,
                "READY", workshopId, "Workshop",
                null, null, null, null, null, null,
                1, 0, true, true, version
        };
    }
    private void stubLockAndReplay(
            String status, long version, String packageStatus) {
        Query lock = query();
        when(lock.getResultList()).thenReturn(Collections.singletonList(new Object[]{
                segmentId,
                planId,
                packageId,
                status,
                version,
                packageStatus,
                (short) 1,
                false,
                false,
                false,
                goodsId,
                null,
                true
        }));
        Query replay = query();
        when(replay.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(lock, replay);
    }

    private static Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        return query;
    }
}
