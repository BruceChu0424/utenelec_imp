package com.uten.imp.features.common.taskclaim;

import com.uten.imp.application.port.SalesQuoteFinanceReviewerEligibilityPort;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.quote.SalesQuoteFinanceClaimTargetLocks;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * ADR-134 报价核价认领: 策略登记(查看 + 核价权限、30 分钟租约), 核价人资格 fail-closed(资格端口未注入即拒绝),
 * 认领前锁报价表头并要求仍在待核价。
 */
class SalesQuoteFinanceClaimPolicyTest {

    private static final String TYPE = SalesQuoteFinanceClaimTargetLocks.TARGET_TYPE;

    private final TaskClaimRepository claimRepo = mock(TaskClaimRepository.class);
    private final SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
    private final AuthUser me = mock(AuthUser.class);
    private final EntityManager em = mock(EntityManager.class);
    private final Query headerLock = mock(Query.class);
    private final UUID userId = UUID.randomUUID();
    private final UUID employeeId = UUID.randomUUID();
    private final String key = UUID.randomUUID().toString();
    private TaskClaimService service;

    @BeforeEach
    void setUp() {
        service = new TaskClaimService(claimRepo, mock(EmployeeNameResolver.class), currentUser,
                mock(com.uten.imp.audit.AuditService.class),
                List.of(new SalesQuoteFinanceClaimTargetLocks(em)),
                mock(com.uten.imp.application.port.FinanceReviewerEligibilityPort.class),
                mock(com.uten.imp.application.port.SalesOrderFinanceReviewerEligibilityPort.class));
        when(currentUser.get()).thenReturn(Optional.of(me));
        when(currentUser.requireId()).thenReturn(userId);
        when(currentUser.employeeId()).thenReturn(Optional.of(employeeId));
        when(me.getEmployeeId()).thenReturn(employeeId);
        when(me.getId()).thenReturn(userId);
        when(me.getPermissions()).thenReturn(Set.of("sales_quote_finance:view", "sales_quote_finance:confirm"));
        when(em.createNativeQuery(anyString())).thenReturn(headerLock);
        when(headerLock.setParameter(anyString(), any())).thenReturn(headerLock);
        when(claimRepo.findUnreleasedForUpdate(any(), any())).thenReturn(Optional.empty());
        when(claimRepo.save(any(TaskClaim.class))).thenAnswer(invocation -> invocation.getArgument(0));
    }

    @Test
    void policyNeedsViewToSeeAndConfirmToClaim() {
        TaskClaimPolicy policy = TaskClaimPolicy.of(TYPE);
        assertThat(policy.leaseMinutes()).isEqualTo(30);
        assertThat(policy.claimPermissions()).containsExactly("sales_quote_finance:confirm");
        assertThat(policy.managePermissions()).containsExactly("sales_quote_finance:confirm");
        assertThat(policy.requiredViewPermission()).isEqualTo("sales_quote_finance:view");
    }

    @Test
    void withoutTheEligibilityAdapterNobodyCanClaim() {
        ApiException error = assertThrows(ApiException.class, () -> service.claim(TYPE, key));
        assertEquals(ErrorCode.FORBIDDEN, error.getCode());
        verify(claimRepo, never()).save(any(TaskClaim.class));
    }

    @Test
    void permissionHolderOutsideTheReviewerPoolIsRejected() {
        SalesQuoteFinanceReviewerEligibilityPort eligibility = mock(SalesQuoteFinanceReviewerEligibilityPort.class);
        when(eligibility.isEligible(userId)).thenReturn(false);
        service.setQuoteReviewers(eligibility);
        ApiException error = assertThrows(ApiException.class, () -> service.claim(TYPE, key));
        assertEquals(ErrorCode.FORBIDDEN, error.getCode());
    }

    @Test
    void eligibleReviewerClaimsOnlyAQuoteStillPendingReview() {
        SalesQuoteFinanceReviewerEligibilityPort eligibility = mock(SalesQuoteFinanceReviewerEligibilityPort.class);
        when(eligibility.isEligible(userId)).thenReturn(true);
        service.setQuoteReviewers(eligibility);

        when(headerLock.getResultList()).thenReturn(List.of());
        ApiException gone = assertThrows(ApiException.class, () -> service.claim(TYPE, key));
        assertEquals(ErrorCode.CONFLICT, gone.getCode());

        when(headerLock.getResultList()).thenReturn(List.of(UUID.fromString(key)));
        var view = service.claim(TYPE, key);
        assertThat(view.claimedByMe()).isTrue();
        assertThat(view.targetType()).isEqualTo(TYPE);
    }

    @Test
    void salesCannotChangeAQuoteWhileFinanceHoldsTheClaim() {
        TaskClaim active = new TaskClaim();
        active.setTargetType(TYPE);
        active.setTargetKey(key);
        active.setClaimedBy(UUID.randomUUID());
        active.setClaimedAt(java.time.OffsetDateTime.now());
        active.setLeaseUntil(java.time.OffsetDateTime.now().plusMinutes(20));
        when(claimRepo.findUnreleasedForUpdate(TYPE, key)).thenReturn(Optional.of(active));
        ApiException error = assertThrows(ApiException.class, () -> service.requireNoActiveClaim(TYPE, key));
        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertThat(error.getMessage()).contains("报价").contains("核价中");
    }
}
