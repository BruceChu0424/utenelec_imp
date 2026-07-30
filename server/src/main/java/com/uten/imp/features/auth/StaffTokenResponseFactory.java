package com.uten.imp.features.auth;

import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.JwtService;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Set;

/**
 * Builds staff token responses inside a read transaction.
 *
 * <p>Employee department/position relations are lazy. Keeping response assembly in this
 * separate proxied service prevents refresh rotation from needing an outer transaction
 * while still avoiding detached-entity failures during profile construction.
 */
@Service
public class StaffTokenResponseFactory {

    private static final int SNAPSHOT_RETRIES = 3;

    private final UserAccountRepository userRepo;
    private final EmployeeRepository employeeRepo;
    private final JwtService jwtService;
    private final PermissionResolver permissionResolver;

    public StaffTokenResponseFactory(UserAccountRepository userRepo,
                                     EmployeeRepository employeeRepo,
                                     JwtService jwtService,
                                     PermissionResolver permissionResolver) {
        this.userRepo = userRepo;
        this.employeeRepo = employeeRepo;
        this.jwtService = jwtService;
        this.permissionResolver = permissionResolver;
    }

    @Transactional(readOnly = true)
    public TokenResponse build(UserAccount user, String rawRefresh) {
        AuthorizationSnapshot snapshot = stableAuthorizationSnapshot(user);
        String access = jwtService.issueAccess(
                user.getId(),
                user.getEmployeeId(),
                user.getLoginAccount(),
                snapshot.roles(),
                snapshot.permissions(),
                snapshot.mustChangePassword(),
                snapshot.authVersion(),
                snapshot.authorizationEpoch());
        return new TokenResponse(
                access,
                rawRefresh,
                jwtService.getAccessTtlSeconds(),
                snapshot.mustChangePassword(),
                profileInternal(user, snapshot.roles(), snapshot.permissions()));
    }

    @Transactional(readOnly = true)
    public TokenResponse.UserProfile profile(UserAccount user) {
        return profileInternal(
                user,
                permissionResolver.rolesOf(user.getId()),
                permissionResolver.permsOf(user));
    }

    private TokenResponse.UserProfile profileInternal(
            UserAccount user,
            Set<String> resolvedRoles,
            Set<String> resolvedPermissions) {
        Employee employee = employeeRepo.findById(user.getEmployeeId()).orElse(null);
        List<String> roles = resolvedRoles.stream().sorted().toList();
        List<String> permissions = resolvedPermissions.stream().sorted().toList();
        String department = employee != null && employee.getDepartment() != null
                ? employee.getDepartment().getName()
                : null;
        String position = user.isSuperAdmin()
                || employee == null
                || employee.getPosition() == null
                ? null
                : employee.getPosition().getName();

        return new TokenResponse.UserProfile(
                user.getId().toString(),
                user.getLoginAccount(),
                employee == null ? null : employee.getId().toString(),
                employee == null ? null : employee.getFullName(),
                employee == null ? null : employee.getCode(),
                department,
                position,
                user.isSuperAdmin(),
                roles,
                permissions);
    }

    /**
     * Read the authorization stamp before and after resolving permissions.
     * This prevents a token from combining old permissions with a new epoch
     * during a concurrent admin change.
     */
    private AuthorizationSnapshot stableAuthorizationSnapshot(UserAccount user) {
        for (int attempt = 0; attempt < SNAPSHOT_RETRIES; attempt++) {
            UserAccountRepository.AccountState before = requireActiveState(user.getId());
            Set<String> roles = permissionResolver.rolesOf(user.getId());
            Set<String> permissions = permissionResolver.permsOf(user);
            UserAccountRepository.AccountState after = requireActiveState(user.getId());
            if (before.getAuthVersion() == after.getAuthVersion()
                    && before.getAuthorizationEpoch() == after.getAuthorizationEpoch()) {
                return new AuthorizationSnapshot(
                        roles,
                        permissions,
                        after.isMustChangePassword(),
                        after.getAuthVersion(),
                        after.getAuthorizationEpoch());
            }
        }
        throw new ApiException(ErrorCode.CONFLICT, "权限正在更新，请重试登录");
    }

    private UserAccountRepository.AccountState requireActiveState(java.util.UUID userId) {
        UserAccountRepository.AccountState state = userRepo.findAccountStateById(userId)
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (state.isDeleted() || !"active".equals(state.getStatus())) {
            throw new ApiException(ErrorCode.UNAUTHORIZED);
        }
        return state;
    }

    private record AuthorizationSnapshot(
            Set<String> roles,
            Set<String> permissions,
            boolean mustChangePassword,
            long authVersion,
            long authorizationEpoch) {
    }
}
