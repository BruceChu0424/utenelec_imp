package com.uten.imp.features.production.dailyreport;

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
import static org.mockito.Mockito.when;

class ProductionDailyReportAttachmentAccessPolicyTest {

    @Test void ownerTypeIsStable() {
        assertEquals("PRODUCTION_DAILY_REPORT", new Harness().policy.ownerType());
    }

    @Test void viewPermissionAndOwnerScopeGateReadingWithoutLeakingExistence() {
        var h = new Harness();
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        h.permissions.remove("production_daily_report:view");
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
        h.permissions.add("production_daily_report:view");
        h.scope(Set.of(), Set.of());
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
        h.report.setMakerId(null);
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanManage(h.id, h.user()));
    }

    @Test void approverOrReverserAuthorityBypassesOwnerScopeForReadingOnly() {
        var h = new Harness();
        h.scope(Set.of(), Set.of());
        h.permissions.add("production_daily_report:reverse");
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanManage(h.id, h.user()));
    }

    @Test void readableDelegationAndMissingEditPermissionDoNotBecomeWritable() {
        var h = new Harness();
        h.scope(Set.of(h.owner), Set.of());
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanManage(h.id, h.user()));
        h.scope(Set.of(h.owner), Set.of(h.owner));
        h.permissions.remove("production_daily_report:edit");
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanManage(h.id, h.user()));
    }

    @Test void approvedClosedCanceledDeletedAndMissingReportsAreReadOnlyOrHidden() {
        var h = new Harness();
        assertDoesNotThrow(() -> h.policy.requireCanManage(h.id, h.user()));
        h.report.setStatus((short) 1);
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManage(h.id, h.user()));
        h.report.setStatus((short) 0); h.report.setClosed(true);
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManage(h.id, h.user()));
        h.report.setClosed(false); h.report.setCanceled(true);
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManage(h.id, h.user()));
        h.report.setCanceled(false); h.report.setDeleted(true);
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(UUID.randomUUID(), h.user()));
        denied(ErrorCode.VALIDATION_FAILED, () -> h.policy.requireCanManage(null, h.user()));
    }

    @Test void confirmAndDeleteLockTheReportAndRecheckAfterRefresh() {
        var h = new Harness();
        h.policy.requireCanManageForUpdate(h.id, h.user());
        var sequence = inOrder(h.em);
        sequence.verify(h.em).find(ProductionDailyReport.class, h.id, LockModeType.PESSIMISTIC_WRITE);
        sequence.verify(h.em).refresh(h.report, LockModeType.PESSIMISTIC_WRITE);
    }

    @Test void approvalObservedAfterLockWaitRejectsStaleDraft() {
        var h = new Harness();
        doAnswer(invocation -> { h.report.setStatus((short) 1); return null; })
                .when(h.em).refresh(h.report, LockModeType.PESSIMISTIC_WRITE);
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManageForUpdate(h.id, h.user()));
    }

    private static void denied(ErrorCode code, Runnable operation) {
        assertEquals(code, assertThrows(ApiException.class, operation::run).getCode());
    }

    private static final class Harness {
        final UUID id = UUID.randomUUID(), owner = UUID.randomUUID();
        final EntityManager em = mock(EntityManager.class);
        final OwnerVisibility ownership = mock(OwnerVisibility.class);
        final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        final Set<String> permissions = new HashSet<>(Set.of(
                "production_daily_report:view", "production_daily_report:edit"));
        final ProductionDailyReport report = new ProductionDailyReport();
        final ProductionDailyReportAttachmentAccessPolicy policy;

        Harness() {
            when(current.get()).thenAnswer(ignored -> Optional.of(user()));
            report.setId(id); report.setMakerId(owner); report.setStatus((short) 0);
            scope(Set.of(owner), Set.of(owner));
            when(em.find(ProductionDailyReport.class, id)).thenReturn(report);
            when(em.find(ProductionDailyReport.class, id, LockModeType.PESSIMISTIC_WRITE)).thenReturn(report);
            policy = new ProductionDailyReportAttachmentAccessPolicy(
                    em, new ProductionDocumentAccessPolicy(ownership, current));
        }
        AuthUser user() { return new AuthUser(owner, owner, "owner", Set.of(), Set.copyOf(permissions), false, true, false); }
        void scope(Set<UUID> readable, Set<UUID> writable) {
            when(ownership.evaluate(anyString(), anyString())).thenReturn(new OwnerVisibility.OwnerScope(false, readable, writable));
        }
    }
}
