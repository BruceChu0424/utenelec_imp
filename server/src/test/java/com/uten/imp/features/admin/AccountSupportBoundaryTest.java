package com.uten.imp.features.admin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.rbac.UserRoleRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TemporaryPasswordGenerator;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.security.crypto.password.PasswordEncoder;

import java.time.OffsetDateTime;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class AccountSupportBoundaryTest {

    @Mock
    private UserAccountRepository users;
    @Mock
    private EmployeeRepository employees;
    @Mock
    private RefreshTokenRepository refreshTokens;
    @Mock
    private UserRoleRepository userRoles;
    @Mock
    private PasswordEncoder encoder;
    @Mock
    private TemporaryPasswordGenerator passwords;
    @Mock
    private TxSessionVars tx;
    @Mock
    private SecurityContextCurrentUser currentUser;

    @Test
    void routineSupportCannotOperateOnItself() {
        AdminUserSupport support = new AdminUserSupport(users, currentUser);
        UserAccount target = new UserAccount();
        when(currentUser.requireId()).thenReturn(target.getId());

        assertThrows(
                ApiException.class,
                () -> support.requireAccountSupportTarget(target));
    }

    @Test
    void routineSupportCannotOperateOnSuperAdministrator() {
        AdminUserSupport support = new AdminUserSupport(users, currentUser);
        UserAccount target = new UserAccount();
        target.setSuperAdmin(true);

        assertThrows(
                ApiException.class,
                () -> support.requireAccountSupportTarget(target));
        verify(currentUser, never()).requireId();
    }

    @Test
    void resetUsesRandomTemporaryPasswordAndRevokesAllSessions() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UserAccount target = new UserAccount();
        target.setEmployeeId(UUID.randomUUID());
        UUID targetId = target.getId();
        Employee employee = activeEmployee();
        when(support.require(targetId)).thenReturn(target);
        when(employees.findById(target.getEmployeeId())).thenReturn(Optional.of(employee));
        when(passwords.generate()).thenReturn("Random-Temp-42!Value");
        when(encoder.encode("Random-Temp-42!Value")).thenReturn("argon2-hash");
        when(users.bumpAuthVersion(targetId)).thenReturn(1);

        String temporaryPassword = service(support).resetPassword(targetId);

        assertEquals("Random-Temp-42!Value", temporaryPassword);
        assertEquals("argon2-hash", target.getPasswordHash());
        assertTrue(target.isMustChangePassword());
        assertEquals("active", target.getStatus());
        verify(support).requireAccountSupportTarget(target);
        verify(users).bumpAuthVersion(targetId);
        verify(refreshTokens).revokeAllByUserId(targetId);
    }

    @Test
    void resetDoesNotSilentlyEnableADisabledAccount() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UserAccount target = new UserAccount();
        target.setStatus("disabled");
        UUID targetId = target.getId();
        when(support.require(targetId)).thenReturn(target);
        when(passwords.generate()).thenReturn("Random-Temp-42!Value");
        when(encoder.encode("Random-Temp-42!Value")).thenReturn("argon2-hash");
        when(users.bumpAuthVersion(targetId)).thenReturn(1);

        service(support).resetPassword(targetId);

        assertEquals("disabled", target.getStatus());
        verify(employees, never()).findById(target.getEmployeeId());
    }

    @Test
    void disablingAccountInvalidatesAccessAndRefreshTokens() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UserAccount target = new UserAccount();
        target.setStatus("active");
        UUID targetId = target.getId();
        when(support.require(targetId)).thenReturn(target);
        when(users.bumpAuthVersion(targetId)).thenReturn(1);

        service(support).setStatus(targetId, "disabled");

        assertEquals("disabled", target.getStatus());
        verify(users).save(target);
        verify(users).bumpAuthVersion(targetId);
        verify(refreshTokens).revokeAllByUserId(targetId);
    }

    @Test
    void convertingTemporaryLockToManualLockInvalidatesAllSessions() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UserAccount target = new UserAccount();
        target.setStatus("locked");
        target.setLockedUntil(OffsetDateTime.now().plusMinutes(10));
        UUID targetId = target.getId();
        when(support.require(targetId)).thenReturn(target);
        when(users.bumpAuthVersion(targetId)).thenReturn(1);

        service(support).setStatus(targetId, "locked");

        assertEquals("locked", target.getStatus());
        assertNull(target.getLockedUntil());
        verify(users).save(target);
        verify(users).bumpAuthVersion(targetId);
        verify(refreshTokens).revokeAllByUserId(targetId);
    }

    @Test
    void reactivatingAccountClearsTemporaryLockAndInvalidatesAllSessions() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UserAccount target = new UserAccount();
        target.setEmployeeId(UUID.randomUUID());
        target.setStatus("disabled");
        target.setFailedAttempts(4);
        target.setLockedUntil(OffsetDateTime.now().plusMinutes(10));
        UUID targetId = target.getId();
        when(support.require(targetId)).thenReturn(target);
        when(employees.findById(target.getEmployeeId()))
                .thenReturn(Optional.of(activeEmployee()));
        when(users.bumpAuthVersion(targetId)).thenReturn(1);

        service(support).setStatus(targetId, "active");

        assertEquals("active", target.getStatus());
        assertEquals(0, target.getFailedAttempts());
        assertNull(target.getLockedUntil());
        verify(users).save(target);
        verify(users).bumpAuthVersion(targetId);
        verify(refreshTokens).revokeAllByUserId(targetId);
    }

    @Test
    void repeatedAccountStatusIsANoOp() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UserAccount target = new UserAccount();
        target.setStatus("disabled");
        UUID targetId = target.getId();
        when(support.require(targetId)).thenReturn(target);

        service(support).setStatus(targetId, "disabled");

        verify(users, never()).save(target);
        verify(users, never()).bumpAuthVersion(targetId);
        verify(refreshTokens, never()).revokeAllByUserId(targetId);
    }

    @Test
    void unlockInvalidatesPreviouslyIssuedAccessToken() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UserAccount target = new UserAccount();
        target.setEmployeeId(UUID.randomUUID());
        target.setStatus("locked");
        target.setFailedAttempts(3);
        UUID targetId = target.getId();
        when(support.require(targetId)).thenReturn(target);
        when(employees.findById(target.getEmployeeId()))
                .thenReturn(Optional.of(activeEmployee()));
        when(users.bumpAuthVersion(targetId)).thenReturn(1);

        service(support).unlock(targetId);

        assertEquals("active", target.getStatus());
        assertEquals(0, target.getFailedAttempts());
        verify(users).bumpAuthVersion(targetId);
        verify(refreshTokens).revokeAllByUserId(targetId);
    }

    @Test
    void unlockingCleanActiveAccountIsANoOp() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UserAccount target = new UserAccount();
        target.setStatus("active");
        UUID targetId = target.getId();
        when(support.require(targetId)).thenReturn(target);

        service(support).unlock(targetId);

        verify(employees, never()).findById(target.getEmployeeId());
        verify(users, never()).save(target);
        verify(users, never()).bumpAuthVersion(targetId);
        verify(refreshTokens, never()).revokeAllByUserId(targetId);
    }

    private Employee activeEmployee() {
        Employee employee = new Employee();
        employee.setStatus("active");
        return employee;
    }

    private UserAccountAdminService service(AdminUserSupport support) {
        return new UserAccountAdminService(
                users,
                employees,
                refreshTokens,
                userRoles,
                encoder,
                passwords,
                tx,
                support);
    }
}
