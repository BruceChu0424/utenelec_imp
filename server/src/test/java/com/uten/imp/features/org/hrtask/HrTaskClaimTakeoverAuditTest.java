package com.uten.imp.features.org.hrtask;

import com.uten.imp.audit.AuditService;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.OffsetDateTime;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class HrTaskClaimTakeoverAuditTest {

    private HrTaskClaimRepository repository;
    private SecurityContextCurrentUser currentUser;
    private AuditService audit;
    private HrTaskClaimService service;
    private AuthUser user;
    private final UUID me = UUID.randomUUID();
    private final UUID other = UUID.randomUUID();
    private final UUID employeeId = UUID.randomUUID();

    @BeforeEach
    void setUp() {
        repository = mock(HrTaskClaimRepository.class);
        EmployeeRepository employees = mock(EmployeeRepository.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        audit = mock(AuditService.class);
        user = mock(AuthUser.class);
        when(currentUser.requireEmployeeId()).thenReturn(me);
        when(currentUser.get()).thenReturn(Optional.of(user));
        when(user.getId()).thenReturn(UUID.randomUUID());
        when(user.getLoginAccount()).thenReturn("hr-auditor");
        when(repository.save(any(HrTaskClaim.class)))
                .thenAnswer(invocation -> invocation.getArgument(0));
        when(employees.findById(any(UUID.class))).thenAnswer(invocation -> {
            Employee employee = mock(Employee.class);
            when(employee.getFullName()).thenReturn(
                    invocation.getArgument(0).equals(employeeId) ? "目标员工" : "处理人");
            return Optional.of(employee);
        });
        service = new HrTaskClaimService(repository, employees, currentUser, audit);
    }

    @Test
    void currentOwnerTakeoverIsRecordedAsManualRenew() {
        HrTaskClaim mine = active(me);
        when(repository.findFirstByTaskTypeAndEmployeeIdAndReleasedAtIsNull(
                "confirm", employeeId)).thenReturn(Optional.of(mine), Optional.of(mine));

        assertTrue(service.takeover("confirm", employeeId).claimedByMe());

        verify(audit).logCommitted(
                eq(user.getId()), eq("hr-auditor"), eq("hr_task_renew"),
                eq("hr_task_claims"), eq("confirm · 目标员工"), eq("success"));
    }

    @Test
    void replacingAnotherOwnerWritesOneTakeoverEvent() {
        when(repository.findFirstByTaskTypeAndEmployeeIdAndReleasedAtIsNull(
                "confirm", employeeId))
                .thenReturn(Optional.of(active(other)), Optional.empty());

        assertTrue(service.takeover("confirm", employeeId).claimedByMe());

        verify(audit).logCommitted(
                eq(user.getId()), eq("hr-auditor"), eq("hr_task_takeover"),
                eq("hr_task_claims"), eq("confirm · 目标员工"), eq("success"));
    }

    @Test
    void noActiveOwnerIsRecordedAsClaim() {
        when(repository.findFirstByTaskTypeAndEmployeeIdAndReleasedAtIsNull(
                "confirm", employeeId)).thenReturn(Optional.empty(), Optional.empty());

        assertTrue(service.takeover("confirm", employeeId).claimedByMe());

        verify(audit).logCommitted(
                eq(user.getId()), eq("hr-auditor"), eq("hr_task_claim"),
                eq("hr_task_claims"), eq("confirm · 目标员工"), eq("success"));
    }

    @Test
    void claimingOwnActiveHrTaskIsRecordedAsRenewNotNewClaim() {
        when(repository.findFirstByTaskTypeAndEmployeeIdAndReleasedAtIsNull(
                "confirm", employeeId)).thenReturn(Optional.of(active(me)));

        assertTrue(service.claim("confirm", employeeId).claimedByMe());

        verify(audit).logCommitted(
                eq(user.getId()), eq("hr-auditor"), eq("hr_task_renew"),
                eq("hr_task_claims"), eq("confirm · 目标员工"), eq("success"));
        verify(audit, never()).logCommitted(
                any(), any(), eq("hr_task_claim"), any(), any(), any());
    }

    private HrTaskClaim active(UUID owner) {
        HrTaskClaim claim = new HrTaskClaim();
        claim.setTaskType("confirm");
        claim.setEmployeeId(employeeId);
        claim.setClaimedBy(owner);
        claim.setClaimedAt(OffsetDateTime.now().minusMinutes(1));
        claim.setLeaseUntil(OffsetDateTime.now().plusHours(1));
        return claim;
    }
}
