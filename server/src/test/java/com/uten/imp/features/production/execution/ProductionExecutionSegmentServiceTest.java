package com.uten.imp.features.production.execution;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
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
import org.springframework.transaction.annotation.Transactional;

import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class ProductionExecutionSegmentServiceTest {

    private final UUID planId = UUID.randomUUID();
    private final UUID segmentId = UUID.randomUUID();
    private final UUID packageId = UUID.randomUUID();
    private final UUID planMakerId = UUID.randomUUID();
    private EntityManager em;
    private final UUID goodsId = UUID.randomUUID();
    private SecurityContextCurrentUser currentUser;
    private ProductionGoodsWorkshopPreferenceService workshopPreferences;
    private ProductionExecutionReadinessService readiness;
    private ProductionAssignmentValidator assignmentValidator;
    private ChainNoticeService chainNotice;
    private ProductionDocumentAccessPolicy access;
    private ProductionExecutionSegmentService service;

    @BeforeEach
    void setUp() {
        em = mock(EntityManager.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        workshopPreferences = mock(ProductionGoodsWorkshopPreferenceService.class);
        readiness = mock(ProductionExecutionReadinessService.class);
        assignmentValidator = mock(ProductionAssignmentValidator.class);
        chainNotice = mock(ChainNoticeService.class);
        access = mock(ProductionDocumentAccessPolicy.class);
        service = new ProductionExecutionSegmentService(
                em,
                workshopPreferences,
                readiness,
                assignmentValidator,
                currentUser,
                mock(TxSessionVars.class),
                chainNotice,
                access);
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
        Query planOwner = query();
        when(planOwner.getResultList()).thenReturn(List.of(planMakerId));
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
                planOwner, lock, replay, update, view, event);

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
    void objectScopeDenialStopsBeforeReplayAndMutation() {
        Query lock = locked("READY", 2L, "CONFIRMED");
        when(em.createNativeQuery(anyString())).thenReturn(lock);
        doThrow(new ApiException(ErrorCode.FORBIDDEN, "无权操作"))
                .when(access)
                .requireScopedOperationWritable(
                        planMakerId,
                        "无权操作此生产计划的执行任务",
                        "production_execution:dispatch");

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.dispatch(
                        planId,
                        segmentId,
                        new SegmentTransitionRequest(
                                2L, "dispatch-scope-denied")));

        assertTrue(error.getMessage().contains("无权操作"));
        verifyNoInteractions(chainNotice, readiness);
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

    @Test
    void startRejectsWhenNoMaterialDemandHasBeenIssued() {
        Query lock = locked(
                "DISPATCHED", 3L, "CONFIRMED", null, true, "DEMANDED");
        Query replay = query();
        when(replay.getResultList()).thenReturn(List.of());
        Query demands = query();
        when(demands.getResultList()).thenReturn(List.of(
                new Object[]{UUID.randomUUID(), "ALLOCATED"},
                new Object[]{UUID.randomUUID(), "ALLOCATED"}));
        when(em.createNativeQuery(anyString())).thenReturn(lock, replay, demands);

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.start(
                        planId,
                        segmentId,
                        new SegmentTransitionRequest(3L, "start-key-unissued")));

        assertTrue(error.getMessage().contains("待发料 2 项"));
        verifyNoInteractions(chainNotice);
    }

    @Test
    void startRejectsWhenOnlyPartOfTheMaterialDemandsAreFulfilled() {
        Query lock = locked(
                "DISPATCHED", 4L, "CONFIRMED", null, true, "DEMANDED");
        Query replay = query();
        when(replay.getResultList()).thenReturn(List.of());
        Query demands = query();
        when(demands.getResultList()).thenReturn(List.of(
                new Object[]{UUID.randomUUID(), "FULFILLED"},
                new Object[]{UUID.randomUUID(), "ALLOCATED"}));
        when(em.createNativeQuery(anyString())).thenReturn(lock, replay, demands);

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.start(
                        planId,
                        segmentId,
                        new SegmentTransitionRequest(4L, "start-key-partial")));

        assertTrue(error.getMessage().contains("待发料 1 项"));
        verifyNoInteractions(chainNotice);
    }

    @Test
    void startSucceedsAfterEveryMaterialDemandIsFulfilled() {
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        Query lock = locked(
                "DISPATCHED", 5L, "CONFIRMED", null, true, "DEMANDED");
        Query replay = query();
        when(replay.getResultList()).thenReturn(List.of());
        Query demands = query();
        when(demands.getResultList()).thenReturn(List.of(
                new Object[]{UUID.randomUUID(), "FULFILLED"},
                new Object[]{UUID.randomUUID(), "FULFILLED"}));
        Query update = query();
        when(update.executeUpdate()).thenReturn(1);
        Query event = query();
        when(event.executeUpdate()).thenReturn(1);
        Query view = query();
        when(view.getResultList()).thenReturn(Collections.singletonList(
                viewRow("IN_PROGRESS", null, 6L, 2, 2, true)));
        when(em.createNativeQuery(anyString())).thenReturn(
                lock, replay, demands, update, event, view);

        assertDoesNotThrow(() -> service.start(
                planId,
                segmentId,
                new SegmentTransitionRequest(5L, "start-key-fulfilled")));

        verify(chainNotice).notifyExecutionSegmentTransition(segmentId, true);
    }

    @Test
    void zeroMaterialSegmentCanStartWithoutDemandRows() {
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        Query lock = locked(
                "DISPATCHED", 8L, "CONFIRMED", null, true, "ZERO_MATERIAL");
        Query replay = query();
        when(replay.getResultList()).thenReturn(List.of());
        Query update = query();
        when(update.executeUpdate()).thenReturn(1);
        Query event = query();
        when(event.executeUpdate()).thenReturn(1);
        Query view = query();
        when(view.getResultList()).thenReturn(Collections.singletonList(
                viewRow("IN_PROGRESS", null, 9L, 0, 0, true)));
        when(em.createNativeQuery(anyString())).thenReturn(
                lock, replay, update, event, view);

        assertDoesNotThrow(() -> service.start(
                planId,
                segmentId,
                new SegmentTransitionRequest(8L, "start-key-zero-material")));

        verify(chainNotice).notifyExecutionSegmentTransition(segmentId, true);
    }

    @Test
    void batchStartDeduplicatesAndLocksInUuidOrderBeforeAnyMutation() {
        UUID firstId = UUID.fromString("00000000-0000-0000-0000-000000000001");
        UUID secondId = UUID.fromString("00000000-0000-0000-0000-000000000002");
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());

        Query firstLock = locked(
                firstId, "DISPATCHED", 3L, "CONFIRMED", null, true,
                "DEMANDED");
        Query secondLock = locked(
                secondId, "DISPATCHED", 7L, "CONFIRMED", null, true,
                "DEMANDED");
        Query firstReplay = query();
        when(firstReplay.getResultList()).thenReturn(List.of());
        Query firstDemands = query();
        when(firstDemands.getResultList()).thenReturn(Collections.singletonList(
                new Object[]{UUID.randomUUID(), "FULFILLED"}));
        Query secondReplay = query();
        when(secondReplay.getResultList()).thenReturn(List.of());
        Query secondDemands = query();
        when(secondDemands.getResultList()).thenReturn(Collections.singletonList(
                new Object[]{UUID.randomUUID(), "FULFILLED"}));
        Query firstUpdate = query();
        when(firstUpdate.executeUpdate()).thenReturn(1);
        Query firstEvent = query();
        when(firstEvent.executeUpdate()).thenReturn(1);
        Query firstView = query();
        when(firstView.getResultList()).thenReturn(Collections.singletonList(
                viewRow(firstId, "IN_PROGRESS", null, 4L, 1, 1, true)));
        Query secondUpdate = query();
        when(secondUpdate.executeUpdate()).thenReturn(1);
        Query secondEvent = query();
        when(secondEvent.executeUpdate()).thenReturn(1);
        Query secondView = query();
        when(secondView.getResultList()).thenReturn(Collections.singletonList(
                viewRow(secondId, "IN_PROGRESS", null, 8L, 1, 1, true)));
        when(em.createNativeQuery(anyString())).thenReturn(
                firstLock, secondLock,
                firstReplay, firstDemands,
                secondReplay, secondDemands,
                firstUpdate, firstEvent, firstView,
                secondUpdate, secondEvent, secondView);

        BatchStartRequest.Item first = new BatchStartRequest.Item(
                firstId, 3L, "batch-start-first");
        BatchStartRequest.Item second = new BatchStartRequest.Item(
                secondId, 7L, "batch-start-second");
        List<ExecutionSegmentView> result = service.batchStart(
                planId, new BatchStartRequest(List.of(second, first, second)));

        assertEquals(List.of(firstId, secondId), result.stream()
                .map(ExecutionSegmentView::id)
                .toList());
        var lockOrder = inOrder(firstLock, secondLock, firstUpdate);
        lockOrder.verify(firstLock).setParameter("segmentId", firstId);
        lockOrder.verify(secondLock).setParameter("segmentId", secondId);
        lockOrder.verify(firstUpdate).executeUpdate();
        verify(em, times(12)).createNativeQuery(anyString());
        verify(chainNotice).notifyExecutionSegmentTransition(firstId, true);
        verify(chainNotice).notifyExecutionSegmentTransition(secondId, true);
    }

    @Test
    void batchStartPreflightsEveryItemBeforeTheFirstStatusUpdate()
            throws Exception {
        UUID firstId = UUID.fromString("00000000-0000-0000-0000-000000000011");
        UUID secondId = UUID.fromString("00000000-0000-0000-0000-000000000012");
        Query firstLock = locked(
                firstId, "DISPATCHED", 2L, "CONFIRMED", null, true,
                "DEMANDED");
        Query secondLock = locked(
                secondId, "DISPATCHED", 4L, "CONFIRMED", null, true,
                "DEMANDED");
        Query firstReplay = query();
        when(firstReplay.getResultList()).thenReturn(List.of());
        Query firstDemands = query();
        when(firstDemands.getResultList()).thenReturn(Collections.singletonList(
                new Object[]{UUID.randomUUID(), "FULFILLED"}));
        Query secondReplay = query();
        when(secondReplay.getResultList()).thenReturn(List.of());
        Query secondDemands = query();
        when(secondDemands.getResultList()).thenReturn(Collections.singletonList(
                new Object[]{UUID.randomUUID(), "ALLOCATED"}));
        when(em.createNativeQuery(anyString())).thenReturn(
                firstLock, secondLock,
                firstReplay, firstDemands,
                secondReplay, secondDemands);

        ApiException error = assertThrows(ApiException.class, () ->
                service.batchStart(planId, new BatchStartRequest(List.of(
                        new BatchStartRequest.Item(
                                secondId, 4L, "batch-preflight-second"),
                        new BatchStartRequest.Item(
                                firstId, 2L, "batch-preflight-first")))));

        assertTrue(error.getMessage().contains("待发料 1 项"));
        verify(em, times(6)).createNativeQuery(anyString());
        verifyNoInteractions(chainNotice);

        Method method = ProductionExecutionSegmentService.class
                .getDeclaredMethod(
                        "batchStart", UUID.class, BatchStartRequest.class);
        Transactional transactional = method.getAnnotation(Transactional.class);
        assertNotNull(transactional);
        assertEquals(false, transactional.readOnly());
    }

    @Test
    void batchStartSafelyReplaysEveryPreviouslyCommittedItem() {
        UUID firstId = UUID.fromString("00000000-0000-0000-0000-000000000021");
        UUID secondId = UUID.fromString("00000000-0000-0000-0000-000000000022");
        String firstKey = "batch-replay-first";
        String secondKey = "batch-replay-second";
        Query firstLock = locked(
                firstId, "IN_PROGRESS", 6L, "CONFIRMED", null, true,
                "DEMANDED");
        Query secondLock = locked(
                secondId, "IN_PROGRESS", 9L, "CONFIRMED", null, true,
                "DEMANDED");
        Query firstReplay = query();
        when(firstReplay.getResultList()).thenReturn(Collections.singletonList(
                new Object[]{startHash(5L), 6L}));
        Query firstView = query();
        when(firstView.getResultList()).thenReturn(Collections.singletonList(
                viewRow(firstId, "IN_PROGRESS", null, 6L, 1, 1, true)));
        Query secondReplay = query();
        when(secondReplay.getResultList()).thenReturn(Collections.singletonList(
                new Object[]{startHash(8L), 9L}));
        Query secondView = query();
        when(secondView.getResultList()).thenReturn(Collections.singletonList(
                viewRow(secondId, "IN_PROGRESS", null, 9L, 1, 1, true)));
        when(em.createNativeQuery(anyString())).thenReturn(
                firstLock, secondLock,
                firstReplay, firstView,
                secondReplay, secondView);

        List<ExecutionSegmentView> result = service.batchStart(
                planId, new BatchStartRequest(List.of(
                        new BatchStartRequest.Item(secondId, 8L, secondKey),
                        new BatchStartRequest.Item(firstId, 5L, firstKey))));

        assertEquals(List.of(firstId, secondId), result.stream()
                .map(ExecutionSegmentView::id)
                .toList());
        verify(em, times(6)).createNativeQuery(anyString());
        verifyNoInteractions(chainNotice);
    }

    @Test
    void batchStartRejectsTheSameIdempotencyKeyWithDifferentVersion() {
        UUID targetId = UUID.fromString(
                "00000000-0000-0000-0000-000000000031");
        Query lock = locked(
                targetId, "IN_PROGRESS", 6L, "CONFIRMED", null, true,
                "DEMANDED");
        Query replay = query();
        when(replay.getResultList()).thenReturn(Collections.singletonList(
                new Object[]{startHash(5L), 6L}));
        when(em.createNativeQuery(anyString())).thenReturn(lock, replay);

        ApiException error = assertThrows(ApiException.class, () ->
                service.batchStart(planId, new BatchStartRequest(List.of(
                        new BatchStartRequest.Item(
                                targetId, 4L, "batch-shared-key")))));

        assertTrue(error.getMessage().contains("相同幂等键"));
        verify(em, times(2)).createNativeQuery(anyString());
        verifyNoInteractions(chainNotice);
    }

    @Test
    void batchStartRejectsAmbiguousDuplicatesBeforeLocking() {
        UUID targetId = UUID.randomUUID();

        ApiException error = assertThrows(ApiException.class, () ->
                service.batchStart(planId, new BatchStartRequest(List.of(
                        new BatchStartRequest.Item(
                                targetId, 1L, "batch-duplicate-one"),
                        new BatchStartRequest.Item(
                                targetId, 2L, "batch-duplicate-two")))));

        assertTrue(error.getMessage().contains("重复批量开工请求不一致"));
        verifyNoInteractions(em, chainNotice);
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
        return locked(
                status, version, packageStatus, workshopId,
                autoPromoteWhenReady, "DEMANDED");
    }

    private Query locked(
            String status, long version, String packageStatus,
            UUID workshopId, boolean autoPromoteWhenReady,
            String materialRequirementMode) {
        return locked(
                segmentId, status, version, packageStatus, workshopId,
                autoPromoteWhenReady, materialRequirementMode);
    }

    private Query locked(
            UUID targetSegmentId,
            String status,
            long version,
            String packageStatus,
            UUID workshopId,
            boolean autoPromoteWhenReady,
            String materialRequirementMode) {
        Query lock = query();
        when(lock.getResultList()).thenReturn(
                Collections.singletonList(new Object[]{
                        targetSegmentId,
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
                        // s.responsible_employee_id（V474 起进入 lock 投影）
                        null,
                        autoPromoteWhenReady,
                        materialRequirementMode,
                        planMakerId
                }));
        return lock;
    }

    private Object[] viewRow(UUID workshopId, long version) {
        return viewRow("READY", workshopId, version, 2, 2, true);
    }

    private Object[] viewRow(
            String status,
            UUID workshopId,
            long version,
            int demandCount,
            int fulfilledCount,
            boolean materialIssued) {
        return viewRow(
                segmentId, status, workshopId, version,
                demandCount, fulfilledCount, materialIssued);
    }

    private Object[] viewRow(
            UUID targetSegmentId,
            String status,
            UUID workshopId,
            long version,
            int demandCount,
            int fulfilledCount,
            boolean materialIssued) {
        return new Object[]{
                targetSegmentId, packageId, planId, UUID.randomUUID(),
                1, "SEG-1", goodsId, "G-1", "Goods",
                null, UUID.randomUUID(),
                BigDecimal.ONE, BigDecimal.ZERO, BigDecimal.ONE,
                status, workshopId, "Workshop",
                null, null, null, null, null, null,
                1, 0, true, true,
                demandCount, fulfilledCount, materialIssued,
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO,
                BigDecimal.ONE, BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                version
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
                // s.responsible_employee_id（V474 起进入 lock 投影）
                null,
                true,
                "DEMANDED",
                planMakerId
        }));
        Query replay = query();
        when(replay.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(lock, replay);
    }

    private static String startHash(long expectedVersion) {
        return PlanningPackageFingerprint.sha256(List.of(
                "ACTION|START", "VERSION|" + expectedVersion));
    }

    private static Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        return query;
    }
}
