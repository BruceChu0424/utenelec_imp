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

import java.util.UUID;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
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

        assertThrows(ApiException.class,
                () -> support.requireAccountSupportTarget(target));
    }

    @Test
    void routineSupportCannotOperateOnSuperAdministrator() {
        AdminUserSupport support = new AdminUserSupport(users, currentUser);
        UserAccount target = new UserAccount();
        target.setSuperAdmin(true);

        assertThrows(ApiException.class,
                () -> support.requireAccountSupportTarget(target));
        verify(currentUser, never()).requireId();
    }

    @Test
    void resetUsesRandomTemporaryPasswordAndRevokesAllRefreshTokens() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UserAccount target = new UserAccount();
        target.setEmployeeId(UUID.randomUUID());
        UUID targetId = target.getId();
        Employee employee = new Employee();
        employee.setStatus("active");
        when(support.require(targetId)).thenReturn(target);
        when(employees.findById(target.getEmployeeId()))
                .thenReturn(Optional.of(employee));
        when(passwords.generate()).thenReturn("Random-Temp-42!Value");
        when(encoder.encode("Random-Temp-42!Value")).thenReturn("argon2-hash");

        UserAccountAdminService service = new UserAccountAdminService(
                users,
                employees,
                refreshTokens,
                userRoles,
                encoder,
                passwords,
                tx,
                support);

        String temporaryPassword = service.resetPassword(targetId);

        assertEquals("Random-Temp-42!Value", temporaryPassword);
        assertEquals("argon2-hash", target.getPasswordHash());
        assertTrue(target.isMustChangePassword());
        assertEquals("active", target.getStatus());
        verify(support).requireAccountSupportTarget(target);
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
        UserAccountAdminService service = new UserAccountAdminService(
                users,
                employees,
                refreshTokens,
                userRoles,
                encoder,
                passwords,
                tx,
                support);

        service.resetPassword(targetId);

        assertEquals("disabled", target.getStatus());
        verify(employees, never()).findById(target.getEmployeeId());
    }
}
