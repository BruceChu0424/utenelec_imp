package com.uten.imp.features.auth;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.JwtService;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

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
        UUID userId = user.getId();
        AuthorizationSnapshot snapshot = stableAuthorizationSnapshot(userId);
        String access = jwtService.issueAccess(
                userId,
                snapshot.authVersion(),
                snapshot.authorizationEpoch());
        return new TokenResponse(
                access,
                rawRefresh,
                jwtService.getAccessTtlSeconds(),
                snapshot.mustChangePassword(),
                profileInternal(userId, snapshot));
    }

    @Transactional(readOnly = true)
    public TokenResponse.UserProfile profile(UserAccount user) {
        UUID userId = user.getId();
        return profileInternal(userId, stableAuthorizationSnapshot(userId));
    }

    private TokenResponse.UserProfile profileInternal(
            UUID userId,
            AuthorizationSnapshot snapshot) {
        Employee employee = employeeRepo.findById(snapshot.employeeId()).orElse(null);
        List<String> roles = snapshot.roles().stream().sorted().toList();
        List<String> permissions = snapshot.permissions().stream().sorted().toList();
        String department = employee != null && employee.getDepartment() != null
                ? employee.getDepartment().getName()
                : null;
        String position = snapshot.superAdmin()
                || employee == null
                || employee.getPosition() == null
                ? null
                : employee.getPosition().getName();

        return new TokenResponse.UserProfile(
                userId.toString(),
                snapshot.loginAccount(),
                employee == null ? null : employee.getId().toString(),
                employee == null ? null : employee.getFullName(),
                employee == null ? null : employee.getCode(),
                department,
                position,
                snapshot.superAdmin(),
                roles,
                permissions);
    }

    /**
     * Resolve identity, authorization shape and effective authorities from the same
     * current database state. The passed UserAccount may be detached after refresh
     * rotation or cleared by a native auth-version bump, so none of its mutable fields
     * are used to build the token response.
     */
    private AuthorizationSnapshot stableAuthorizationSnapshot(UUID userId) {
        for (int attempt = 0; attempt < SNAPSHOT_RETRIES; attempt++) {
            UserAccountRepository.AccountState before = requireActiveState(userId);
            PermissionResolver.AuthorizationSnapshot authorities =
                    permissionResolver.authorizationSnapshot(
                            userId,
                            before.getEmployeeId(),
                            before.isSuperAdmin());
            UserAccountRepository.AccountState after = requireActiveState(userId);
            if (sameAuthorizationState(before, after)) {
                return new AuthorizationSnapshot(
                        after.getEmployeeId(),
                        after.getLoginAccount(),
                        after.isSuperAdmin(),
                        authorities.roles(),
                        authorities.permissions(),
                        after.isMustChangePassword(),
                        after.getAuthVersion(),
                        after.getAuthorizationEpoch());
            }
        }
        throw new ApiException(ErrorCode.CONFLICT, "权限正在更新，请重试登录");
    }

    private boolean sameAuthorizationState(
            UserAccountRepository.AccountState before,
            UserAccountRepository.AccountState after) {
        return before.getAuthVersion() == after.getAuthVersion()
                && before.getAuthorizationEpoch() == after.getAuthorizationEpoch()
                && Objects.equals(before.getEmployeeId(), after.getEmployeeId())
                && Objects.equals(before.getLoginAccount(), after.getLoginAccount())
                && before.isSuperAdmin() == after.isSuperAdmin()
                && before.isMustChangePassword() == after.isMustChangePassword();
    }

    private UserAccountRepository.AccountState requireActiveState(UUID userId) {
        UserAccountRepository.AccountState state = userRepo.findAccountStateById(userId)
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (state.isDeleted()
                || !"active".equals(state.getStatus())
                || state.getEmployeeId() == null
                || state.getLoginAccount() == null
                || state.getLoginAccount().isBlank()) {
            throw new ApiException(ErrorCode.UNAUTHORIZED);
        }
        return state;
    }

    private record AuthorizationSnapshot(
            UUID employeeId,
            String loginAccount,
            boolean superAdmin,
            Set<String> roles,
            Set<String> permissions,
            boolean mustChangePassword,
            long authVersion,
            long authorizationEpoch) {
    }
}
