package com.uten.imp.features.production.plan;

import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import org.junit.jupiter.api.Test;

import java.util.HashSet;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionPlanAttachmentAccessPolicyTest {

    @Test void ownerTypeIsStable() {
        assertEquals("PRODUCTION_PLAN", new Harness().policy.ownerType());
    }

    @Test void viewPermissionAndOwnerScopeGateReadingWithoutLeakingExistence() {
        var h = new Harness();
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        h.permissions.remove("production_plan:view");
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
        h.permissions.add("production_plan:view");
        h.scope(Set.of(), Set.of());
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
        h.plan.setMakerId(null);
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanManage(h.id, h.user()));
    }

    @Test void approverAuthorityBypassesOwnerScopeForReadingOnly() {
        var h = new Harness();
        h.scope(Set.of(), Set.of());
        h.permissions.add("production_plan:approve");
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanManage(h.id, h.user()));
    }

    @Test void readableDelegationDoesNotBecomeWritable() {
        var h = new Harness();
        h.scope(Set.of(h.owner), Set.of());
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanManage(h.id, h.user()));
        h.permissions.remove("production_plan:edit");
        h.scope(Set.of(h.owner), Set.of(h.owner));
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanManage(h.id, h.user()));
    }

    @Test void approvedClosedStoppedCanceledDeletedAndMissingPlansAreReadOnlyOrHidden() {
        var h = new Harness();
        assertDoesNotThrow(() -> h.policy.requireCanManage(h.id, h.user()));
        h.plan.setStatus((short) 1);
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManage(h.id, h.user()));
        h.plan.setStatus((short) 0); h.plan.setClosed(true);
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManage(h.id, h.user()));
        h.plan.setClosed(false); h.plan.setStopped(true);
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManage(h.id, h.user()));
        h.plan.setStopped(false); h.plan.setCanceled(true);
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManage(h.id, h.user()));
        h.plan.setCanceled(false); h.plan.setDeleted(true);
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(UUID.randomUUID(), h.user()));
        denied(ErrorCode.VALIDATION_FAILED, () -> h.policy.requireCanManage(null, h.user()));
    }

    @Test void confirmAndDeleteLockThePlanAndRecheckAfterRefresh() {
        var h = new Harness();
        h.policy.requireCanManageForUpdate(h.id, h.user());
        var sequence = inOrder(h.mutations, h.em, h.guard);
        sequence.verify(h.mutations).beginPlan(h.id, List.of());
        sequence.verify(h.em).find(ProductionPlan.class, h.id, LockModeType.PESSIMISTIC_WRITE);
        sequence.verify(h.em).refresh(h.plan, LockModeType.PESSIMISTIC_WRITE);
        sequence.verify(h.guard).verifyUnchanged();
    }

    @Test void approvalObservedAfterLockWaitRejectsStaleDraft() {
        var h = new Harness();
        doAnswer(invocation -> { h.plan.setStatus((short) 1); return null; })
                .when(h.em).refresh(h.plan, LockModeType.PESSIMISTIC_WRITE);
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManageForUpdate(h.id, h.user()));
        verify(h.guard, never()).verifyUnchanged();
    }

    private static void denied(ErrorCode code, Runnable operation) {
        assertEquals(code, assertThrows(ApiException.class, operation::run).getCode());
    }

    private static final class Harness {
        final UUID id = UUID.randomUUID(), owner = UUID.randomUUID();
        final EntityManager em = mock(EntityManager.class);
        final OwnerVisibility ownership = mock(OwnerVisibility.class);
        final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        final ProductionPlanMutationFootprintService mutations = mock(ProductionPlanMutationFootprintService.class);
        final FulfillmentMutationLocks.Guard guard = mock(FulfillmentMutationLocks.Guard.class);
        final Set<String> permissions = new HashSet<>(Set.of("production_plan:view", "production_plan:edit"));
        final ProductionPlan plan = new ProductionPlan();
        final ProductionPlanAttachmentAccessPolicy policy;

        Harness() {
            when(current.get()).thenAnswer(ignored -> Optional.of(user()));
            plan.setId(id); plan.setMakerId(owner); plan.setStatus((short) 0);
            scope(Set.of(owner), Set.of(owner));
            when(em.find(ProductionPlan.class, id)).thenReturn(plan);
            when(em.find(ProductionPlan.class, id, LockModeType.PESSIMISTIC_WRITE)).thenReturn(plan);
            when(mutations.beginPlan(id, List.of())).thenReturn(guard);
            policy = new ProductionPlanAttachmentAccessPolicy(
                    em, new ProductionDocumentAccessPolicy(ownership, current), mutations);
        }
        AuthUser user() { return new AuthUser(owner, owner, "owner", Set.of(), Set.copyOf(permissions), false, true, false); }
        void scope(Set<UUID> readable, Set<UUID> writable) {
            when(ownership.evaluate(anyString(), anyString())).thenReturn(new OwnerVisibility.OwnerScope(false, readable, writable));
        }
    }
}
