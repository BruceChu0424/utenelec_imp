package com.uten.imp.features.auth;

import com.uten.imp.common.identity.CurrentEmployeeStatusPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import java.time.Instant;
import java.util.UUID;

/** Staff authentication eligibility; super-admin privileges never replace a live employee identity. */
public final class StaffAuthenticationPolicy {
    private StaffAuthenticationPolicy() {}

    public static boolean currentEmployee(UUID employeeId, boolean deleted, String status) {
        return employeeId != null && !deleted && status != null && CurrentEmployeeStatusPolicy.isCurrentEmployee(status);
    }

    public static boolean currentEmployee(UserAccountRepository users, UserAccount account) {
        return account.getEmployeeId() != null && users.existsAuthenticatableEmployee(
                account.getEmployeeId(), CurrentEmployeeStatusPolicy.CURRENT_EMPLOYEE_STATUSES);
    }

    public static void requireCurrentEmployee(UserAccountRepository users, UserAccount account) {
        if (!currentEmployee(users, account)) throw new ApiException(ErrorCode.UNAUTHORIZED);
    }

    public static boolean temporaryPasswordExpired(boolean mustChangePassword, Instant expiresAt) {
        return mustChangePassword && expiresAt != null && !expiresAt.isAfter(Instant.now());
    }

    public static boolean temporaryPasswordExpired(UserAccount account) {
        return temporaryPasswordExpired(account.isMustChangePassword(),
                account.getTempPasswordExpiresAt() == null ? null : account.getTempPasswordExpiresAt().toInstant());
    }

    public static void requireCurrentTemporaryPassword(UserAccount account) {
        if (temporaryPasswordExpired(account)) throw new ApiException(ErrorCode.UNAUTHORIZED,
                "临时密码已过期，请联系管理员重新设置临时密码");
    }
}
