package com.uten.imp.features.expenseclaim;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.finance.EmployeeClaimPostingPort;
import com.uten.imp.common.finance.EmployeeClaimPostingPort.EmployeeClaimPosting;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimCreateRequest;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimItemInput;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimPaymentRequest;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ExpenseClaimServiceTest {

    private ExpenseClaimRepository claimRepository;
    private ExpenseClaimItemRepository itemRepository;
    private ExpenseApplicantQuery applicantQuery;
    private EmployeeClaimPostingPort postingPort;
    private SecurityContextCurrentUser currentUser;
    private com.uten.imp.features.common.taskclaim.TaskClaimService taskClaim;
    private ExpenseClaimService service;
    private AuthUser authUser;
    private UUID actorId;

    @BeforeEach
    void setUp() {
        claimRepository = mock(ExpenseClaimRepository.class);
        itemRepository = mock(ExpenseClaimItemRepository.class);
        applicantQuery = mock(ExpenseApplicantQuery.class);
        postingPort = mock(EmployeeClaimPostingPort.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        taskClaim = mock(com.uten.imp.features.common.taskclaim.TaskClaimService.class);
        authUser = mock(AuthUser.class);
        actorId = UUID.randomUUID();

        when(currentUser.get()).thenReturn(Optional.of(authUser));
        when(authUser.isVisitor()).thenReturn(false);
        when(authUser.isSuperAdmin()).thenReturn(false);
        when(authUser.getEmployeeId()).thenReturn(actorId);

        service = new ExpenseClaimService(
                claimRepository,
                itemRepository,
                applicantQuery,
                postingPort,
                currentUser,
                mock(TxSessionVars.class),
                taskClaim);
    }

    @Test
    void createCalculatesTotalOnServer() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply"));
        when(applicantQuery.findEligible(actorId)).thenReturn(Optional.of(
                new ExpenseApplicantQuery.ApplicantSnapshot("员工甲", UUID.randomUUID())));

        var result = service.create(new ExpenseClaimCreateRequest(
                "差旅报销",
                null,
                List.of(
                        new ExpenseClaimItemInput(
                                "travel", new BigDecimal("12.30"), LocalDate.now(), "住宿"),
                        new ExpenseClaimItemInput(
                                "MEAL", new BigDecimal("7.70"), LocalDate.now(), "餐费"))));

        assertEquals(new BigDecimal("20.00"), result.totalAmount());
        assertEquals("DRAFT", result.status());
        assertEquals(2, result.items().size());
        verify(itemRepository).saveAll(any());
    }

    @Test
    void applicantCannotApproveOwnClaim() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:approve"));
        ExpenseClaim claim = claim(actorId, "SUBMITTED");
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));

        ApiException error = assertThrows(ApiException.class, () -> service.approve(claim.getId()));

        assertEquals(ErrorCode.FORBIDDEN, error.getCode());
        verify(claimRepository, never()).save(any());
    }

    @Test
    void applicantCannotPayOwnClaim() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:pay"));
        ExpenseClaim claim = claim(actorId, "APPROVED");
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));

        ApiException error = assertThrows(ApiException.class, () -> service.pay(
                claim.getId(), payment()));

        assertEquals(ErrorCode.FORBIDDEN, error.getCode());
        verify(postingPort, never()).postEmployeeClaim(any());
    }

    @Test
    void paidRetryWithSameParametersIsIdempotent() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:pay"));
        ExpenseClaimPaymentRequest payment = payment();
        ExpenseClaim claim = claim(UUID.randomUUID(), "PAID");
        claim.setPaymentAccountId(payment.accountId());
        claim.setPaymentExpenseStyleId(payment.expenseStyleId());
        claim.setPaymentDate(payment.paymentDate());
        claim.setFinanceExpenseId(UUID.randomUUID());
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        when(itemRepository.findByClaimIdInOrderByClaimIdAscLineNoAsc(any()))
                .thenReturn(List.of());

        var result = service.pay(claim.getId(), payment);

        assertEquals("PAID", result.status());
        verify(postingPort, never()).postEmployeeClaim(any());
        verify(claimRepository, never()).save(any());
    }

    @Test
    void approvedPaymentPostsFinanceThenMarksClaimPaid() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:pay"));
        ExpenseClaim claim = claim(UUID.randomUUID(), "APPROVED");
        ExpenseClaimPaymentRequest payment = payment();
        UUID financeExpenseId = UUID.randomUUID();
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        when(postingPort.postEmployeeClaim(any(EmployeeClaimPosting.class)))
                .thenReturn(financeExpenseId);
        when(itemRepository.findByClaimIdInOrderByClaimIdAscLineNoAsc(any()))
                .thenReturn(List.of());

        var result = service.pay(claim.getId(), payment);

        assertEquals("PAID", result.status());
        assertEquals(financeExpenseId, claim.getFinanceExpenseId());
        verify(postingPort).postEmployeeClaim(any(EmployeeClaimPosting.class));
        verify(claimRepository).save(claim);
    }

    @Test
    void postingFailureDoesNotMarkClaimPaid() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:pay"));
        ExpenseClaim claim = claim(UUID.randomUUID(), "APPROVED");
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        when(postingPort.postEmployeeClaim(any(EmployeeClaimPosting.class)))
                .thenThrow(new IllegalStateException("posting failed"));

        assertThrows(IllegalStateException.class, () -> service.pay(claim.getId(), payment()));

        assertEquals("APPROVED", claim.getStatus());
        verify(claimRepository, never()).save(any());
    }

    @Test
    void approverCannotReadSomeoneElsesDraft() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:approve"));
        ExpenseClaim claim = claim(UUID.randomUUID(), "DRAFT");
        when(claimRepository.findById(claim.getId())).thenReturn(Optional.of(claim));

        ApiException error = assertThrows(ApiException.class, () -> service.detail(claim.getId()));

        assertEquals(ErrorCode.NOT_FOUND, error.getCode());
    }

    private static ExpenseClaim claim(UUID applicantId, String status) {
        ExpenseClaim claim = new ExpenseClaim();
        claim.setApplicantId(applicantId);
        claim.setApplicantNameSnapshot("员工甲");
        claim.setApplicantDepartmentId(UUID.randomUUID());
        claim.setTitle("差旅报销");
        claim.setTotalAmount(new BigDecimal("100.00"));
        claim.setStatus(status);
        return claim;
    }

    private static ExpenseClaimPaymentRequest payment() {
        return new ExpenseClaimPaymentRequest(
                UUID.randomUUID(), UUID.randomUUID(), LocalDate.now());
    }
}
