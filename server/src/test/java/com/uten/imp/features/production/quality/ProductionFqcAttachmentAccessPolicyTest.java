package com.uten.imp.features.production.quality;

import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.quality.ProductionFqcContracts.InspectionView;
import com.uten.imp.security.AuthUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.math.BigDecimal;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class ProductionFqcAttachmentAccessPolicyTest {
    @Test void exactInspectionScopeIsRequiredForOriginalEvidence() {
        var h = new Harness();
        doThrow(new ApiException(ErrorCode.NOT_FOUND, "hidden inspection"))
                .when(h.inspections).detail(h.id);
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanManage(h.id, h.user()));
        verifyNoInteractions(h.mutations);
    }

    @Test void actionPermissionAloneCannotBypassQualityOrganization() {
        var h = new Harness();
        doThrow(new ApiException(ErrorCode.FORBIDDEN, "not in quality pool"))
                .when(h.tasks).requireQualityPool(anyString());
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanManageForUpdate(h.id, h.user()));
        verifyNoInteractions(h.mutations);
    }

    @ParameterizedTest @ValueSource(strings = {"PARTIAL", "RESOLVED", "CANCELLED"})
    void historicalAndPartlyDecidedEvidenceIsImmutableButRemainsReadable(String status) {
        var h = new Harness(); when(h.view.status()).thenReturn(status);
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManage(h.id, h.user()));
    }

    @Test void inconsistentPendingSnapshotWithPriorDecisionCannotReplaceEvidence() {
        var h = new Harness(); when(h.view.passedQty()).thenReturn(BigDecimal.ONE);
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManage(h.id, h.user()));
    }

    @Test void confirmationAndDeletionUseTheBusinessLockThenActualInspectionRow() {
        var h = new Harness();
        h.policy.requireCanManageForUpdate(h.id, h.user());
        var order = inOrder(h.mutations, h.em, h.query, h.inspections, h.guard);
        order.verify(h.mutations).beginInspections(List.of(h.id));
        order.verify(h.em).createNativeQuery(contains("FOR UPDATE"));
        order.verify(h.query).getResultList();
        order.verify(h.inspections).detail(h.id);
        order.verify(h.guard).verifyUnchanged();
    }

    @Test void decisionCommittedWhileWaitingForLockBlocksFileMutation() {
        var h = new Harness();
        when(h.query.getResultList()).thenAnswer(ignored -> {
            when(h.view.status()).thenReturn("PARTIAL");
            return List.of(h.id);
        });
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManageForUpdate(h.id, h.user()));
        verify(h.guard, never()).verifyUnchanged();
    }

    @Test void viewerCannotMutateAndMissingPermissionDoesNotLeakInspection() {
        var h = new Harness(); h.permissions.remove("production_quality_inspection:approve");
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanManage(h.id, h.user()));
        h.permissions.remove("production_quality_inspection:view");
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.VALIDATION_FAILED, () -> h.policy.requireCanManage(null, h.user()));
    }

    private static void denied(ErrorCode code, Runnable operation) {
        assertEquals(code, assertThrows(ApiException.class, operation::run).getCode());
    }

    private static class Harness {
        final UUID id = UUID.randomUUID(), actor = UUID.randomUUID();
        final Set<String> permissions = new HashSet<>(Set.of("production_quality_inspection:view", "production_quality_inspection:approve"));
        final EntityManager em = mock(EntityManager.class);
        final Query query = mock(Query.class);
        final ProductionFqcInspectionService inspections = mock(ProductionFqcInspectionService.class);
        final ProductionFqcTaskAccessPolicy tasks = mock(ProductionFqcTaskAccessPolicy.class);
        final ProductionQualityMutationFootprintService mutations = mock(ProductionQualityMutationFootprintService.class);
        final FulfillmentMutationLocks.Guard guard = mock(FulfillmentMutationLocks.Guard.class);
        final InspectionView view = mock(InspectionView.class);
        final ProductionFqcAttachmentAccessPolicy policy = new ProductionFqcAttachmentAccessPolicy(em, inspections, tasks, mutations);
        Harness() {
            when(inspections.detail(id)).thenReturn(view);
            when(view.status()).thenReturn("PENDING");
            when(view.passedQty()).thenReturn(BigDecimal.ZERO);
            when(view.failedQty()).thenReturn(BigDecimal.ZERO);
            when(view.remainingQty()).thenReturn(BigDecimal.TEN);
            when(mutations.beginInspections(List.of(id))).thenReturn(guard);
            when(em.createNativeQuery(anyString())).thenReturn(query);
            when(query.setParameter("id", id)).thenReturn(query);
            when(query.getResultList()).thenReturn(List.of(id));
            assertEquals("PRODUCTION_QUALITY_INSPECTION", policy.ownerType());
        }
        AuthUser user() { return new AuthUser(actor, actor, "quality", Set.of(), Set.copyOf(permissions), false, true, false); }
    }
}
