package com.uten.imp.features.common.taskclaim;

import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.OffsetDateTime;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * {@link TaskClaimService} 单元测试：聚焦"show-as-locked"语义与重复操作守卫
 * {@link TaskClaimService#requireNoActiveClaimByOther}。该基础设施此前在本分支无测试。
 */
class TaskClaimServiceTest {

    private TaskClaimRepository claimRepo;
    private EmployeeNameResolver nameResolver;
    private SecurityContextCurrentUser currentUser;
    private AuthUser meUser;
    private com.uten.imp.audit.AuditService audit;
    private jakarta.persistence.EntityManager em;
    private com.uten.imp.application.port.FinanceReviewerEligibilityPort procurementReviewers;
    private com.uten.imp.application.port.SalesOrderFinanceReviewerEligibilityPort salesReviewers;
    private com.uten.imp.application.port.ReviewTaskTargetLockPort procurementTargets;
    private TaskClaimService service;

    private static final String TYPE = "EXPENSE_APPROVE";
    private static final String KEY = "claim-uuid-1";
    private final UUID me = UUID.randomUUID();
    private final UUID other = UUID.randomUUID();
    private final UUID actor = UUID.randomUUID();

    @Test
    void commercialMutationCannotBypassItsOwnActiveReviewClaim() {
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE, KEY))
                .thenReturn(Optional.of(activeClaim(me)));
        assertThrows(ApiException.class, () -> service.requireNoActiveClaim(TYPE, KEY));
        assertDoesNotThrow(() -> service.requireNoActiveClaimByOther(TYPE, KEY));
    }

    @BeforeEach
    void setUp() {
        claimRepo = mock(TaskClaimRepository.class);
        nameResolver = mock(EmployeeNameResolver.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        meUser = mock(AuthUser.class);
        audit = mock(com.uten.imp.audit.AuditService.class);
        em = mock(jakarta.persistence.EntityManager.class);
        procurementReviewers = mock(com.uten.imp.application.port.FinanceReviewerEligibilityPort.class);
        salesReviewers = mock(com.uten.imp.application.port.SalesOrderFinanceReviewerEligibilityPort.class);
        procurementTargets=mock(com.uten.imp.application.port.ReviewTaskTargetLockPort.class);
        when(procurementTargets.targetType()).thenReturn("PROCUREMENT_FINANCE_APPROVE");
        when(procurementTargets.resolve(org.mockito.ArgumentMatchers.anyList(),org.mockito.ArgumentMatchers.anyBoolean()))
                .thenAnswer(invocation -> ((java.util.List<String>)invocation.getArgument(0)).stream()
                        .map(key -> new com.uten.imp.application.port.ReviewTaskTargetLockPort.Target(key,"PURCHASE",
                                UUID.nameUUIDFromBytes(key.getBytes(java.nio.charset.StandardCharsets.UTF_8)),
                                UUID.nameUUIDFromBytes(key.getBytes(java.nio.charset.StandardCharsets.UTF_8)))).toList());
        service = new TaskClaimService(
                claimRepo,nameResolver,currentUser,audit,java.util.List.of(
                        new com.uten.imp.features.sales.order.SalesFinanceClaimTargetLocks(em),procurementTargets),procurementReviewers,salesReviewers);

        when(currentUser.get()).thenReturn(Optional.of(meUser));
        when(currentUser.employeeId()).thenReturn(Optional.of(me));
        when(meUser.isSuperAdmin()).thenReturn(false);
        when(meUser.getId()).thenReturn(actor);
        when(currentUser.requireId()).thenReturn(actor);
        when(meUser.getLoginAccount()).thenReturn("auditor");
        when(meUser.getEmployeeId()).thenReturn(me);
        when(nameResolver.nameOf(any(UUID.class))).thenReturn("张三");
        // claim() 会 save 认领记录，回传同一对象便于断言
        when(claimRepo.save(any(TaskClaim.class))).thenAnswer(inv -> inv.getArgument(0));
        when(claimRepo.findUnreleasedForUpdate(any(), any())).thenAnswer(inv ->
                claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(
                        inv.getArgument(0), inv.getArgument(1)));
    }

    private TaskClaim activeClaim(UUID claimedBy) {
        TaskClaim c = new TaskClaim();
        c.setTargetType(TYPE);
        c.setTargetKey(KEY);
        c.setClaimedBy(claimedBy);
        c.setClaimedAt(OffsetDateTime.now().minusMinutes(1));
        c.setLeaseUntil(OffsetDateTime.now().plusMinutes(20));
        c.setLastHeartbeat(OffsetDateTime.now());
        return c;
    }

    @Test
    void financialDecisionRequiresLiveOwnLeaseAndTheSameClaimGeneration() {
        String type="PROCUREMENT_FINANCE_APPROVE", key=UUID.randomUUID().toString();
        when(meUser.getPermissions()).thenReturn(Set.of("finance_order_approval:view","finance_order_approval:approve"));
        var eligible=new com.uten.imp.application.port.FinanceReviewerEligibilityPort.EligibleFinanceReviewer(actor,me,"审核员");
        when(procurementReviewers.findEligible(actor)).thenReturn(Optional.of(eligible));
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> service.requireActiveClaimByMe(type,key,null)).getCode());
        TaskClaim expired=activeClaim(me); expired.setLeaseUntil(OffsetDateTime.now().minusSeconds(1));
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(type,key)).thenReturn(Optional.of(expired));
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> service.requireActiveClaimByMe(type,key,expired.getId())).getCode());
        TaskClaim theirs=activeClaim(other);
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(type,key)).thenReturn(Optional.of(theirs));
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> service.requireActiveClaimByMe(type,key,theirs.getId())).getCode());
        TaskClaim mine=activeClaim(me);
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(type,key)).thenReturn(Optional.of(mine));
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> service.requireActiveClaimByMe(type,key,UUID.randomUUID())).getCode());
        assertDoesNotThrow(() -> service.requireActiveClaimByMe(type,key,mine.getId()));
        verify(claimRepo,never()).save(any());
    }

    @Test
    void decisionPermissionWithoutItsFinancialPageViewCannotClaim() {
        when(meUser.getPermissions()).thenReturn(Set.of("finance_order_approval:approve"));
        assertEquals(ErrorCode.FORBIDDEN,assertThrows(ApiException.class,
                () -> service.claim("PROCUREMENT_FINANCE_APPROVE",UUID.randomUUID().toString())).getCode());
        org.mockito.Mockito.verifyNoInteractions(claimRepo,procurementReviewers);
    }

    @Test
    void oldWindowCannotRenewOrReleaseANewerClaimByTheSameEmployee() {
        when(meUser.getPermissions()).thenReturn(Set.of("expense:approve"));
        when(currentUser.requireEmployeeId()).thenReturn(me);
        TaskClaim replacement=activeClaim(me);
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE,KEY)).thenReturn(Optional.of(replacement));
        UUID old=UUID.randomUUID();
        OffsetDateTime lease=replacement.getLeaseUntil();
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> service.heartbeat(TYPE,KEY,old)).getCode());
        service.release(TYPE,KEY,old);
        assertEquals(null,replacement.getReleasedAt());
        assertEquals(lease,replacement.getLeaseUntil());
        verify(claimRepo,never()).save(any());
        service.release(TYPE,KEY,replacement.getId());
        org.junit.jupiter.api.Assertions.assertNotNull(replacement.getReleasedAt());
    }

    @Test
    void eligibilityRevokedWhileWaitingForTargetLockCannotCreateAClaim() {
        String type="PROCUREMENT_FINANCE_APPROVE", key=UUID.randomUUID().toString();
        when(meUser.getPermissions()).thenReturn(Set.of("finance_order_approval:view","finance_order_approval:approve"));
        var eligible=new com.uten.imp.application.port.FinanceReviewerEligibilityPort.EligibleFinanceReviewer(actor,me,"审核员");
        when(procurementReviewers.findEligible(actor)).thenReturn(Optional.of(eligible),Optional.empty());
        assertEquals(ErrorCode.FORBIDDEN,assertThrows(ApiException.class,() -> service.claim(type,key)).getCode());
        org.mockito.Mockito.verifyNoInteractions(claimRepo);
    }

    // ===== requireNoActiveClaimByOther：动作端点重复操作守卫 =====

    @Test
    void noActiveClaimAllowsAction() {
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE, KEY))
                .thenReturn(Optional.empty());
        assertDoesNotThrow(() -> service.requireNoActiveClaimByOther(TYPE, KEY));
    }

    @Test
    void activeClaimByOtherBlocksAction() {
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE, KEY))
                .thenReturn(Optional.of(activeClaim(other)));
        ApiException ex = assertThrows(ApiException.class,
                () -> service.requireNoActiveClaimByOther(TYPE, KEY));
        assertEquals(ErrorCode.CONFLICT, ex.getCode());
    }

    @Test
    void activeClaimBySelfDoesNotBlock() {
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE, KEY))
                .thenReturn(Optional.of(activeClaim(me)));
        assertDoesNotThrow(() -> service.requireNoActiveClaimByOther(TYPE, KEY));
    }

    @Test
    void expiredLeaseDoesNotBlockEvenIfByOther() {
        TaskClaim expired = activeClaim(other);
        expired.setLeaseUntil(OffsetDateTime.now().minusMinutes(1)); // 租约过期 → isActive=false
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE, KEY))
                .thenReturn(Optional.of(expired));
        assertDoesNotThrow(() -> service.requireNoActiveClaimByOther(TYPE, KEY));
    }

    @Test
    void anonymousCallerBlockedIfOthersClaimActive() {
        when(currentUser.employeeId()).thenReturn(Optional.empty()); // 无员工绑定
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE, KEY))
                .thenReturn(Optional.of(activeClaim(other)));
        ApiException ex = assertThrows(ApiException.class,
                () -> service.requireNoActiveClaimByOther(TYPE, KEY));
        assertEquals(ErrorCode.CONFLICT, ex.getCode());
    }

    // ===== claim：第一个人认领胜出，他人 409 =====

    @Test
    void firstClaimSucceeds() {
        when(meUser.getPermissions()).thenReturn(Set.of("expense:approve"));
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE, KEY))
                .thenReturn(Optional.empty());
        TaskClaimService.TaskClaimView view = service.claim(TYPE, KEY);
        assertTrue(view.claimedByMe());
        assertEquals(me, view.claimedBy());
        verify(audit).logCommitted(
                eq(meUser.getId()), eq("auditor"), eq("task_claim"),
                eq("task_claims"), eq(TYPE + "/" + KEY), eq("success"));
    }

    @Test
    void claimByOtherIsRejected() {
        when(meUser.getPermissions()).thenReturn(Set.of("expense:approve"));
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE, KEY))
                .thenReturn(Optional.of(activeClaim(other)));
        ApiException ex = assertThrows(ApiException.class, () -> service.claim(TYPE, KEY));
        assertEquals(ErrorCode.CONFLICT, ex.getCode());
    }

    @Test
    void claimingOwnActiveLeaseIsRecordedAsRenewNotNewClaim() {
        when(meUser.getPermissions()).thenReturn(Set.of("expense:approve"));
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE, KEY))
                .thenReturn(Optional.of(activeClaim(me)));

        assertTrue(service.claim(TYPE, KEY).claimedByMe());

        verify(audit).logCommitted(
                eq(meUser.getId()), eq("auditor"), eq("task_renew"),
                eq("task_claims"), eq(TYPE + "/" + KEY), eq("success"));
        verify(audit, never()).logCommitted(
                any(), any(), eq("task_claim"), any(), any(), any());
    }

    @Test
    void heartbeatBeforeRenewalThresholdDoesNotWriteOrAudit() {
        when(meUser.getPermissions()).thenReturn(Set.of("expense:approve"));
        TaskClaim claim = activeClaim(me);
        claim.setLeaseUntil(OffsetDateTime.now().plusMinutes(20));
        when(currentUser.requireEmployeeId()).thenReturn(me);
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE, KEY))
                .thenReturn(Optional.of(claim));

        TaskClaimService.TaskClaimView view = service.heartbeat(TYPE, KEY);

        assertEquals(claim.getLeaseUntil(), view.leaseUntil());
        verify(claimRepo, never()).save(any(TaskClaim.class));
        verify(audit, never()).logCommitted(any(), any(), any(), any(), any(), any());
    }

    @Test
    void heartbeatInsideRenewalThresholdExtendsLeaseOnceWithoutExplicitAudit() {
        when(meUser.getPermissions()).thenReturn(Set.of("expense:approve"));
        TaskClaim claim = activeClaim(me);
        OffsetDateTime oldLease = OffsetDateTime.now().plusMinutes(5);
        claim.setLeaseUntil(oldLease);
        when(currentUser.requireEmployeeId()).thenReturn(me);
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE, KEY))
                .thenReturn(Optional.of(claim));

        TaskClaimService.TaskClaimView view = service.heartbeat(TYPE, KEY);

        assertTrue(view.leaseUntil().isAfter(oldLease));
        verify(claimRepo).save(claim);
        verify(audit, never()).logCommitted(any(), any(), any(), any(), any(), any());
    }

    @Test
    void losingAnyTaskTypesClaimPermissionPreventsHeartbeatBeforeLeaseMutation() {
        when(meUser.getPermissions()).thenReturn(Set.of());
        TaskClaim claim = activeClaim(me);
        claim.setLeaseUntil(OffsetDateTime.now().plusMinutes(1));
        OffsetDateTime lease = claim.getLeaseUntil();
        OffsetDateTime heartbeat = claim.getLastHeartbeat();
        for (String targetType : java.util.List.of("EXPENSE_APPROVE", "PURCHASE_DECOMPOSE",
                "SALES_ORDER_APPROVE", "FULFILLMENT_TASK_EDIT", "FULFILLMENT_TASK_APPROVE",
                "SALES_ORDER_FINANCE_CONFIRM", "PROCUREMENT_FINANCE_APPROVE", "IQC_INSPECT")) {
            when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(targetType, KEY))
                    .thenReturn(Optional.of(claim));
            ApiException error = assertThrows(ApiException.class,
                    () -> service.heartbeat(targetType, KEY));
            assertEquals(ErrorCode.FORBIDDEN, error.getCode());
        }
        assertEquals(lease, claim.getLeaseUntil());
        assertEquals(heartbeat, claim.getLastHeartbeat());
        org.mockito.Mockito.verifyNoInteractions(em);
        verify(claimRepo, never()).save(any(TaskClaim.class));
    }

    @Test
    void havingPermissionDoesNotAllowRenewingAnotherEmployeesClaim() {
        when(meUser.getPermissions()).thenReturn(Set.of("expense:approve"));
        TaskClaim claim = activeClaim(other);
        claim.setLeaseUntil(OffsetDateTime.now().plusMinutes(1));
        OffsetDateTime lease = claim.getLeaseUntil();
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE, KEY))
                .thenReturn(Optional.of(claim));
        ApiException error = assertThrows(ApiException.class, () -> service.heartbeat(TYPE, KEY));
        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertEquals(lease, claim.getLeaseUntil());
        verify(claimRepo, never()).save(any(TaskClaim.class));
    }

    @Test
    void claimAndHeartbeatBothRejectASalesOrderThatLeftTheReviewableState() {
        String type = "SALES_ORDER_FINANCE_CONFIRM";
        String key = UUID.randomUUID().toString();
        when(meUser.getPermissions()).thenReturn(Set.of("sales_order_finance:view","sales_order_finance:confirm"));
        when(salesReviewers.isEligible(actor)).thenReturn(true);
        jakarta.persistence.Query query = mock(jakarta.persistence.Query.class);
        when(em.createNativeQuery(org.mockito.ArgumentMatchers.anyString())).thenReturn(query);
        when(query.setParameter(org.mockito.ArgumentMatchers.anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(java.util.List.of());
        assertEquals(ErrorCode.CONFLICT, assertThrows(ApiException.class,
                () -> service.claim(type, key)).getCode());
        assertEquals(ErrorCode.CONFLICT, assertThrows(ApiException.class,
                () -> service.heartbeat(type, key)).getCode());
        org.mockito.Mockito.verifyNoInteractions(claimRepo);
    }

    @Test
    void eitherCurrentProcurementDecisionPermissionSupportsClaimHeartbeatAndTakeover() {
        String type = "PROCUREMENT_FINANCE_APPROVE";
        when(procurementReviewers.findEligible(actor)).thenReturn(Optional.of(
                new com.uten.imp.application.port.FinanceReviewerEligibilityPort.EligibleFinanceReviewer(actor, me, "审核员")));
        for (String permission : java.util.List.of("finance_order_approval:approve", "finance_order_approval:reject")) {
            when(meUser.getPermissions()).thenReturn(Set.of(permission,"finance_order_approval:view"));
            String key = UUID.randomUUID().toString();
            when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(type, key)).thenReturn(Optional.empty());
            assertTrue(service.claim(type, key).claimedByMe());
            TaskClaim mine = activeClaim(me);
            mine.setLeaseUntil(OffsetDateTime.now().plusMinutes(1));
            when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(type, key)).thenReturn(Optional.of(mine));
            assertTrue(service.heartbeat(type, key).claimedByMe());
            when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(type, key))
                    .thenReturn(Optional.of(activeClaim(other)), Optional.empty());
            assertTrue(service.takeover(type, key).claimedByMe());
        }
        verify(procurementReviewers, org.mockito.Mockito.times(12)).findEligible(actor);
    }

    @Test
    void retiredProcurementReviewPermissionCannotClaimHeartbeatOrTakeover() {
        when(meUser.getPermissions()).thenReturn(Set.of("finance_order_approval:view","finance_order_approval:review"));
        String type = "PROCUREMENT_FINANCE_APPROVE";
        assertEquals(ErrorCode.FORBIDDEN, assertThrows(ApiException.class, () -> service.claim(type, KEY)).getCode());
        assertEquals(ErrorCode.FORBIDDEN, assertThrows(ApiException.class, () -> service.heartbeat(type, KEY)).getCode());
        assertEquals(ErrorCode.FORBIDDEN, assertThrows(ApiException.class, () -> service.takeover(type, KEY)).getCode());
        org.mockito.Mockito.verifyNoInteractions(procurementReviewers, claimRepo, em);
    }

    @Test
    void procurementDecisionPermissionWithoutActualEligibilityCannotHoldAClaim() {
        when(meUser.getPermissions()).thenReturn(Set.of("finance_order_approval:view","finance_order_approval:approve"));
        when(procurementReviewers.findEligible(actor)).thenReturn(Optional.empty());
        String type = "PROCUREMENT_FINANCE_APPROVE";
        assertEquals(ErrorCode.FORBIDDEN, assertThrows(ApiException.class, () -> service.claim(type, KEY)).getCode());
        assertEquals(ErrorCode.FORBIDDEN, assertThrows(ApiException.class, () -> service.heartbeat(type, KEY)).getCode());
        assertEquals(ErrorCode.FORBIDDEN, assertThrows(ApiException.class, () -> service.takeover(type, KEY)).getCode());
        org.mockito.Mockito.verifyNoInteractions(claimRepo, em);
    }

    @Test
    void salesPermissionWithoutActualEligibilityCannotClaimHeartbeatOrTakeover() {
        when(meUser.getPermissions()).thenReturn(Set.of("sales_order_finance:view","sales_order_finance:confirm"));
        when(salesReviewers.isEligible(actor)).thenReturn(false);
        String type = "SALES_ORDER_FINANCE_CONFIRM";
        String key = UUID.randomUUID().toString();
        assertEquals(ErrorCode.FORBIDDEN, assertThrows(ApiException.class, () -> service.claim(type, key)).getCode());
        assertEquals(ErrorCode.FORBIDDEN, assertThrows(ApiException.class, () -> service.heartbeat(type, key)).getCode());
        assertEquals(ErrorCode.FORBIDDEN, assertThrows(ApiException.class, () -> service.takeover(type, key)).getCode());
        org.mockito.Mockito.verifyNoInteractions(claimRepo, em);
    }

    @Test
    void salesPersonalGrantEligibilityIsRespectedAndRecheckedBeforeRenewal() {
        String type = "SALES_ORDER_FINANCE_CONFIRM";
        String key = UUID.randomUUID().toString();
        when(meUser.getPermissions()).thenReturn(Set.of("sales_order_finance:view","sales_order_finance:confirm"));
        when(salesReviewers.isEligible(actor)).thenReturn(true);
        jakarta.persistence.Query query = mock(jakarta.persistence.Query.class);
        when(em.createNativeQuery(org.mockito.ArgumentMatchers.anyString())).thenReturn(query);
        when(query.setParameter(org.mockito.ArgumentMatchers.anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(java.util.List.of(UUID.fromString(key)));
        assertTrue(service.claim(type, key).claimedByMe());
        TaskClaim mine = activeClaim(me);
        OffsetDateTime lease = mine.getLeaseUntil();
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(type, key)).thenReturn(Optional.of(mine));
        when(salesReviewers.isEligible(actor)).thenReturn(false);
        assertEquals(ErrorCode.FORBIDDEN, assertThrows(ApiException.class, () -> service.heartbeat(type, key)).getCode());
        assertEquals(lease, mine.getLeaseUntil());
        verify(claimRepo, org.mockito.Mockito.times(1)).save(any(TaskClaim.class));
    }

    @Test
    void takeoverByCurrentOwnerIsRecordedAsManualRenewNotTakeover() {
        when(meUser.getPermissions()).thenReturn(Set.of("expense:approve"));
        TaskClaim mine = activeClaim(me);
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE, KEY))
                .thenReturn(Optional.of(mine), Optional.of(mine));

        TaskClaimService.TaskClaimView view = service.takeover(TYPE, KEY);

        assertTrue(view.claimedByMe());
        verify(audit).logCommitted(
                eq(meUser.getId()), eq("auditor"), eq("task_renew"),
                eq("task_claims"), eq(TYPE + "/" + KEY), eq("success"));
    }

    @Test
    void takeoverIsAuditedOnlyWhenItActuallyReplacesAnotherOwner() {
        when(meUser.getPermissions()).thenReturn(Set.of("expense:approve"));
        TaskClaim theirs = activeClaim(other);
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE, KEY))
                .thenReturn(Optional.of(theirs), Optional.empty());

        TaskClaimService.TaskClaimView view = service.takeover(TYPE, KEY);

        assertTrue(view.claimedByMe());
        verify(audit).logCommitted(
                eq(meUser.getId()), eq("auditor"), eq("task_takeover"),
                eq("task_claims"), eq(TYPE + "/" + KEY), eq("success"));
    }

    @Test
    void takeoverWithoutActiveOwnerIsRecordedAsClaim() {
        when(meUser.getPermissions()).thenReturn(Set.of("expense:approve"));
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE, KEY))
                .thenReturn(Optional.empty(), Optional.empty());

        assertTrue(service.takeover(TYPE, KEY).claimedByMe());

        verify(audit).logCommitted(
                eq(meUser.getId()), eq("auditor"), eq("task_claim"),
                eq("task_claims"), eq(TYPE + "/" + KEY), eq("success"));
    }
}
