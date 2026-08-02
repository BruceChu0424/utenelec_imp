
package com.uten.imp.features.auth;

import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.JwtService;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class StaffTokenResponseFactoryTest {

    @Test
    void responseUsesFreshProjectionIdentityAndAuthorizationShapeForMinimalJwt() {
        UserAccountRepository users = mock(UserAccountRepository.class);
        EmployeeRepository employees = mock(EmployeeRepository.class);
        JwtService jwt = mock(JwtService.class);
        PermissionResolver permissions = mock(PermissionResolver.class);

        UserAccount detached = new UserAccount();
        detached.setEmployeeId(UUID.randomUUID());
        detached.setLoginAccount("STALE");
        detached.setSuperAdmin(true);
        detached.setAuthVersion(6);

        UUID currentEmployeeId = UUID.randomUUID();
        UserAccountRepository.AccountState current =
                state(currentEmployeeId, "E2002", false, false, 7, 11);
        when(users.findAccountStateById(detached.getId())).thenReturn(Optional.of(current));
        when(permissions.authorizationSnapshot(detached.getId(), currentEmployeeId, false))
                .thenReturn(new PermissionResolver.AuthorizationSnapshot(
                        Set.of("employee", "warehouse"),
                        Set.of("employee:view", "stock:view")));

        Employee employee = new Employee();
        employee.setId(currentEmployeeId);
        employee.setCode("E2002");
        employee.setFullName("Current User");
        when(employees.findById(currentEmployeeId)).thenReturn(Optional.of(employee));
        when(jwt.issueAccess(detached.getId(), 7, 11)).thenReturn("small-access-token");
        when(jwt.getAccessTtlSeconds()).thenReturn(900L);

        StaffTokenResponseFactory factory = new StaffTokenResponseFactory(
                users, employees, jwt, permissions);
        TokenResponse response = factory.build(detached, "refresh-token");

        assertEquals("small-access-token", response.accessToken());
        assertEquals("refresh-token", response.refreshToken());
        assertEquals("E2002", response.user().loginAccount());
        assertEquals(currentEmployeeId.toString(), response.user().employeeId());
        assertEquals("Current User", response.user().name());
        assertFalse(response.user().superAdmin());
        assertEquals(java.util.List.of("employee", "warehouse"), response.user().roles());
        assertEquals(java.util.List.of("employee:view", "stock:view"), response.user().permissions());
        verify(jwt).issueAccess(detached.getId(), 7, 11);
        verify(permissions).authorizationSnapshot(detached.getId(), currentEmployeeId, false);
    }

    private UserAccountRepository.AccountState state(
            UUID employeeId,
            String loginAccount,
            boolean superAdmin,
            boolean mustChangePassword,
            long authVersion,
            long authorizationEpoch) {
        UserAccountRepository.AccountState state = mock(UserAccountRepository.AccountState.class);
        when(state.getEmployeeId()).thenReturn(employeeId);
        when(state.getLoginAccount()).thenReturn(loginAccount);
        when(state.getStatus()).thenReturn("active");
        when(state.isDeleted()).thenReturn(false);
        when(state.isSuperAdmin()).thenReturn(superAdmin);
        when(state.isMustChangePassword()).thenReturn(mustChangePassword);
        when(state.getAuthVersion()).thenReturn(authVersion);
        when(state.getAuthorizationEpoch()).thenReturn(authorizationEpoch);
        return state;
    }
}
