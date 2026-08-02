package com.uten.imp.features.production.mrp;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.plan.ProductionPlan;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionPlanningDraftServiceTest {

    private ProductionPlanningDraftRepository draftRepo;
    private ProductionPlanningRequestValidator validator;
    private ProductionExecutionPackageCommandService executionCommand;
    private EntityManager em;
    private SecurityContextCurrentUser currentUser;
    private ObjectMapper objectMapper;
    private ProductionPlanningDraftService service;

    @BeforeEach
    void setUp() {
        draftRepo = mock(ProductionPlanningDraftRepository.class);
        validator = mock(ProductionPlanningRequestValidator.class);
        executionCommand = mock(ProductionExecutionPackageCommandService.class);
        em = mock(EntityManager.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        objectMapper = new ObjectMapper();
        service = new ProductionPlanningDraftService(
                draftRepo, validator, executionCommand, em, currentUser,
                mock(TxSessionVars.class), objectMapper);
    }

    @Test
    void rejectsSavingAgainstApprovedPlanBeforePlanningValidation() {
        UUID planId = UUID.randomUUID();
        ProductionPlan approved = plan(planId, (short) 1);
        when(em.find(ProductionPlan.class, planId,
                LockModeType.PESSIMISTIC_WRITE)).thenReturn(approved);

        assertThatThrownBy(() -> service.save(planId, request()))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode())
                        .isEqualTo(ErrorCode.CONFLICT))
                .hasMessageContaining("仅草稿状态");
        verify(validator, never()).validateCurrent(any(), any());
    }

    @Test
    void repeatsSameHashOnlyWhenCurrentFingerprintAlsoMatches() {
        UUID planId = UUID.randomUUID();
        GeneratePlanningPackageRequest request = request();
        ProductionExecutionPlanningService.Snapshot snapshot = snapshot(
                planId, request);
        when(em.find(ProductionPlan.class, planId,
                LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(plan(planId, (short) 0));
        when(validator.validateCurrent(planId, request))
                .thenReturn(validated(snapshot));
        ProductionPlanningDraft active = active(planId, request);
        when(draftRepo.lockActiveByPlanId(planId))
                .thenReturn(Optional.of(active));

        ProductionPlanningDraftView result = service.save(planId, request);

        assertThat(result.draftId()).isEqualTo(active.getId());
        assertThat(result.request()).isNotNull();
        assertThat(result.request().getWarehouseId())
                .isEqualTo(request.getWarehouseId());
        assertThat(result.request().getPreviewFingerprint())
                .isEqualTo(request.getPreviewFingerprint());
        verify(draftRepo, never()).saveAndFlush(any());
        verify(currentUser, never()).requireId();
    }

    @Test
    void supersedesOldActiveWhenFingerprintChangedEvenWithSameHash() {
        UUID planId = UUID.randomUUID();
        UUID actor = UUID.randomUUID();
        GeneratePlanningPackageRequest request = request();
        ProductionExecutionPlanningService.Snapshot snapshot = snapshot(
                planId, request);
        when(em.find(ProductionPlan.class, planId,
                LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(plan(planId, (short) 0));
        when(validator.validateCurrent(planId, request))
                .thenReturn(validated(snapshot));
        ProductionPlanningDraft active = active(planId, request);
        active.setPreviewFingerprint("b".repeat(64));
        when(draftRepo.lockActiveByPlanId(planId))
                .thenReturn(Optional.of(active));
        when(currentUser.requireId()).thenReturn(actor);

        ProductionPlanningDraftView result = service.save(planId, request);

        assertThat(active.getStatus())
                .isEqualTo(ProductionPlanningDraft.STATUS_SUPERSEDED);
        assertThat(active.getResolvedBy()).isEqualTo(actor);
        ArgumentCaptor<ProductionPlanningDraft> saved =
                ArgumentCaptor.forClass(ProductionPlanningDraft.class);
        verify(draftRepo, times(2)).saveAndFlush(saved.capture());
        ProductionPlanningDraft created = saved.getAllValues().get(1);
        assertThat(created.getStatus())
                .isEqualTo(ProductionPlanningDraft.STATUS_ACTIVE);
        assertThat(created.getPreviewFingerprint())
                .isEqualTo(request.getPreviewFingerprint());
        assertThat(result.draftId()).isEqualTo(created.getId());
    }

    private ProductionPlanningDraft active(
            UUID planId,
            GeneratePlanningPackageRequest request) {
        ProductionPlanningDraft active = new ProductionPlanningDraft();
        active.setPlanId(planId);
        active.setWarehouseId(request.getWarehouseId());
        active.setPayload(objectMapper.valueToTree(request));
        active.setRequestHash(
                ProductionExecutionPackageCommandService.requestHash(request));
        active.setPreviewFingerprint(request.getPreviewFingerprint());
        active.setPlannedBy(UUID.randomUUID());
        return active;
    }

    private static ProductionPlan plan(UUID id, short status) {
        ProductionPlan plan = new ProductionPlan();
        plan.setId(id);
        plan.setStatus(status);
        return plan;
    }

    private static GeneratePlanningPackageRequest request() {
        GeneratePlanningPackageRequest request =
                new GeneratePlanningPackageRequest();
        request.setWarehouseId(UUID.randomUUID());
        request.setIdempotencyKey("planning-draft-test");
        request.setPreviewFingerprint("a".repeat(64));
        request.setSegments(List.of());
        request.setRoutes(List.of());
        return request;
    }

    private static ProductionExecutionPlanningService.Snapshot snapshot(
            UUID planId,
            GeneratePlanningPackageRequest request) {
        return new ProductionExecutionPlanningService.Snapshot(
                planId, request.getWarehouseId(),
                request.getPreviewFingerprint(), List.of(), Map.of(),
                List.of());
    }

    private static ProductionPlanningRequestValidator.Validated validated(
            ProductionExecutionPlanningService.Snapshot snapshot) {
        return new ProductionPlanningRequestValidator.Validated(
                snapshot, Map.of(),
                new CompleteKitAllocator.Allocation(List.of(), Map.of()));
    }
}
