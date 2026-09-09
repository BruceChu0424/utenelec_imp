package com.uten.imp.features.org.employee;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 员工档案附件对象级授权（2026-08-16 保密审计后口径）：
 * view=本人或 employee:pii:view（employee:view 因员工选择器需求已授予几乎所有部门，
 * 不能再作为档案文件——身份证件/合同扫描件——的可见门槛）；manage=employee:edit。
 */
class EmployeeAttachmentAccessPolicyTest {

    private final EmployeeRepository repository = mock(EmployeeRepository.class);
    private final EmployeeAttachmentAccessPolicy policy =
            new EmployeeAttachmentAccessPolicy(repository);

    private final UUID employeeId = UUID.randomUUID();

    private AuthUser user(UUID ownEmployeeId, String... permissions) {
        return new AuthUser(UUID.randomUUID(), ownEmployeeId, "user",
                Set.of(), Set.of(permissions), false, true, false);
    }

    private void employeeExists() {
        when(repository.findById(employeeId)).thenReturn(Optional.of(new Employee()));
    }

    @Test
    void selfCanViewOwnArchiveFiles() {
        employeeExists();
        assertDoesNotThrow(() -> policy.requireCanView(employeeId, user(employeeId)));
    }

    @Test
    void piiViewerCanViewAnyArchive() {
        employeeExists();
        assertDoesNotThrow(() ->
                policy.requireCanView(employeeId, user(null, "employee:pii:view")));
    }

    @Test
    void plainEmployeeViewIsNoLongerSufficient() {
        employeeExists();
        // 关键回归：employee:view（全部门普遍持有）不得放行他人档案附件
        ApiException failure = assertThrows(ApiException.class, () ->
                policy.requireCanView(employeeId, user(null, "employee:view", "attachment:view")));
        assertEquals(ErrorCode.NOT_FOUND, failure.getCode());
    }

    @Test
    void superAdminCanViewAnyArchive() {
        employeeExists();
        AuthUser admin = new AuthUser(UUID.randomUUID(), null, "admin",
                Set.of(), Set.of(), false, true, true);
        assertDoesNotThrow(() -> policy.requireCanView(employeeId, admin));
    }

    @Test
    void manageRequiresEmployeeEditEvenWithPiiView() {
        employeeExists();
        ApiException failure = assertThrows(ApiException.class, () ->
                policy.requireCanManage(employeeId, user(null, "employee:pii:view", "attachment:manage")));
        assertEquals(ErrorCode.NOT_FOUND, failure.getCode());
        assertDoesNotThrow(() ->
                policy.requireCanManage(employeeId, user(null, "employee:edit", "attachment:manage")));
    }

    @Test
    void unknownEmployeeIsNotFoundForEveryone() {
        when(repository.findById(employeeId)).thenReturn(Optional.empty());
        ApiException failure = assertThrows(ApiException.class, () ->
                policy.requireCanView(employeeId, user(employeeId)));
        assertEquals(ErrorCode.NOT_FOUND, failure.getCode());
    }
    @Test
    void selectedAvatarIsVisibleToStaffViewersButTheirArchiveAccessStaysDenied() {
        employeeExists();
        AuthUser viewer = user(null, "employee:view");
        assertDoesNotThrow(() -> policy.requireCanViewAvatar(employeeId, viewer));
        ApiException failure = assertThrows(ApiException.class,
                () -> policy.requireCanView(employeeId, viewer));
        assertEquals(ErrorCode.NOT_FOUND, failure.getCode());
        assertDoesNotThrow(() -> policy.requireCanViewAvatar(employeeId, user(employeeId)));
    }

    @Test
    void selectedAvatarRejectsUnrelatedStaffVisitorsAndUnknownEmployees() {
        employeeExists();
        for (AuthUser caller : new AuthUser[]{
                user(UUID.randomUUID()),
                AuthUser.visitor(UUID.randomUUID(), "visitor", "VIS-1", Set.of("employee:view"))}) {
            ApiException failure = assertThrows(ApiException.class,
                    () -> policy.requireCanViewAvatar(employeeId, caller));
            assertEquals(ErrorCode.NOT_FOUND, failure.getCode());
        }
        when(repository.findById(employeeId)).thenReturn(Optional.empty());
        ApiException failure = assertThrows(ApiException.class,
                () -> policy.requireCanViewAvatar(employeeId, user(null, "employee:view")));
        assertEquals(ErrorCode.NOT_FOUND, failure.getCode());
    }

    @Test
    void avatarEditCanSelectEmployeeAvatarButCannotUploadOrDeleteArchiveFiles() {
        employeeExists();
        AuthUser avatarEditor = user(null, "employee:avatar_edit");

        assertDoesNotThrow(() ->
                policy.requireCanSelectAvatar(employeeId, avatarEditor));
        ApiException failure = assertThrows(ApiException.class, () ->
                policy.requireCanManage(employeeId, avatarEditor));
        assertEquals(ErrorCode.NOT_FOUND, failure.getCode());
    }

    @Test
    void avatarEditCannotDeleteEmployeeContractAttachments() {
        UUID contractId = UUID.randomUUID();
        EmployeeContractRepository contractRepository =
                mock(EmployeeContractRepository.class);
        Employee employee = mock(Employee.class);
        when(employee.getId()).thenReturn(employeeId);
        EmployeeContract contract = mock(EmployeeContract.class);
        when(contract.getEmployee()).thenReturn(employee);
        when(contractRepository.findById(contractId))
                .thenReturn(Optional.of(contract));

        EmployeeContractAttachmentAccessPolicy contractPolicy =
                new EmployeeContractAttachmentAccessPolicy(
                        contractRepository, repository);
        ApiException avatarFailure = assertThrows(ApiException.class, () ->
                contractPolicy.requireCanSelectAvatar(
                        contractId, user(null, "employee:avatar_edit")));
        assertEquals(ErrorCode.VALIDATION_FAILED, avatarFailure.getCode());
        ApiException failure = assertThrows(ApiException.class, () ->
                contractPolicy.requireCanManage(
                        contractId, user(null, "employee:avatar_edit", "attachment:delete")));
        assertEquals(ErrorCode.NOT_FOUND, failure.getCode());
    }
}
