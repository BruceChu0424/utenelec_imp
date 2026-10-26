
package com.uten.imp.features.auth;

import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.JwtService;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.time.Instant;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.times;

class StaffTokenResponseFactoryTest {
    private static final UUID DATASET = UUID.fromString("9be34a91-a856-4b7c-b275-83ba7025c061");

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
                state(currentEmployeeId, "E2002", false, true, 7, 11);
        when(users.findAccountStateById(detached.getId())).thenReturn(Optional.of(current));
        when(current.getBusinessResetGeneration()).thenReturn(9L);
        when(permissions.authorizationSnapshot(detached.getId(), currentEmployeeId, false))
                .thenReturn(new PermissionResolver.AuthorizationSnapshot(
                        Set.of("employee:view", "stock:view")));

        Employee employee = new Employee();
        employee.setId(currentEmployeeId);
        employee.setCode("E2002");
        employee.setFullName("Current User");
        when(employees.findById(currentEmployeeId)).thenReturn(Optional.of(employee));
        UUID sessionId = UUID.randomUUID();
        when(jwt.issueAccess(detached.getId(), 7, 11, sessionId)).thenReturn("small-access-token");
        when(jwt.getAccessTtlSeconds()).thenReturn(900L);

        StaffTokenResponseFactory factory = new StaffTokenResponseFactory(
                users, employees, jwt, permissions);
        TokenResponse response = factory.build(detached, "refresh-token", sessionId);

        assertEquals("small-access-token", response.accessToken());
        assertEquals(9L, response.user().businessResetGeneration());
        assertEquals(DATASET.toString(), response.user().businessDatasetId());
        assertEquals("refresh-token", response.refreshToken());
        assertEquals("E2002", response.user().loginAccount());
        assertEquals(currentEmployeeId.toString(), response.user().employeeId());
        assertEquals("Current User", response.user().name());
        assertTrue(response.mustChangePassword());
        assertTrue(response.user().mustChangePassword());
        assertFalse(response.user().superAdmin());
        assertEquals(java.util.List.of("employee:view", "stock:view"), response.user().permissions());
        verify(jwt).issueAccess(detached.getId(), 7, 11, sessionId);
        verify(permissions).authorizationSnapshot(detached.getId(), currentEmployeeId, false);
    }

    @Test
    void profileAndImpersonationReturnTheSameCanonicalPersistentDatasetIdentity() throws Exception {
        UserAccountRepository users = mock(UserAccountRepository.class);
        EmployeeRepository employees = mock(EmployeeRepository.class);
        JwtService jwt = mock(JwtService.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        UserAccount target = new UserAccount();
        UUID employeeId = UUID.randomUUID();
        var current = state(employeeId, "E2002", false, false, 7, 11);
        when(users.findAccountStateById(target.getId())).thenReturn(Optional.of(current));
        when(permissions.authorizationSnapshot(target.getId(), employeeId, false))
                .thenReturn(new PermissionResolver.AuthorizationSnapshot(Set.of("stock:view")));
        when(employees.findById(employeeId)).thenReturn(Optional.empty());
        var factory = new StaffTokenResponseFactory(users, employees, jwt, permissions);

        var profile = factory.profile(target);
        assertEquals(DATASET.toString(), profile.businessDatasetId());
        var mapper = new com.fasterxml.jackson.databind.ObjectMapper();
        assertEquals(DATASET.toString(), mapper.readTree(mapper.writeValueAsBytes(profile))
                .path("businessDatasetId").asText());
        var impersonated = factory.buildImpersonation(target, UUID.randomUUID(),
                Instant.now().plusSeconds(300), UUID.randomUUID());
        assertEquals(DATASET.toString(), impersonated.user().businessDatasetId());
    }

    @Test
    void datasetChangeDuringPermissionResolutionRetriesTheWholeSnapshot() {
        UserAccountRepository users = mock(UserAccountRepository.class);
        EmployeeRepository employees = mock(EmployeeRepository.class);
        JwtService jwt = mock(JwtService.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        UserAccount target = new UserAccount();
        UUID employeeId = UUID.randomUUID();
        var before = state(employeeId, "E2002", false, false, 7, 11);
        var after = state(employeeId, "E2002", false, false, 7, 11);
        UUID replacement = UUID.randomUUID();
        when(after.getBusinessDatasetId()).thenReturn(replacement);
        when(users.findAccountStateById(target.getId()))
                .thenReturn(Optional.of(before))
                .thenReturn(Optional.of(after))
                .thenReturn(Optional.of(after))
                .thenReturn(Optional.of(after));
        when(permissions.authorizationSnapshot(target.getId(), employeeId, false))
                .thenReturn(new PermissionResolver.AuthorizationSnapshot(Set.of("old:view")),
                        new PermissionResolver.AuthorizationSnapshot(Set.of("current:view")));
        when(employees.findById(employeeId)).thenReturn(Optional.empty());

        var profile = new StaffTokenResponseFactory(users, employees, jwt, permissions).profile(target);
        assertEquals(replacement.toString(), profile.businessDatasetId());
        assertEquals(java.util.List.of("current:view"), profile.permissions());
        verify(permissions, times(2)).authorizationSnapshot(target.getId(), employeeId, false);
    }

    @Test
    void missingDatasetIdentityCannotIssueAnAmbiguousProfile() {
        UserAccountRepository users = mock(UserAccountRepository.class);
        UserAccount target = new UserAccount();
        var current = state(UUID.randomUUID(), "E2002", false, false, 7, 11);
        when(current.getBusinessDatasetId()).thenReturn(null);
        when(users.findAccountStateById(target.getId())).thenReturn(Optional.of(current));
        var factory = new StaffTokenResponseFactory(users, mock(EmployeeRepository.class),
                mock(JwtService.class), mock(PermissionResolver.class));

        assertEquals(ErrorCode.INTERNAL, assertThrows(ApiException.class,
                () -> factory.profile(target)).getCode());
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
        when(state.getBusinessDatasetId()).thenReturn(DATASET);
        return state;
    }
}
