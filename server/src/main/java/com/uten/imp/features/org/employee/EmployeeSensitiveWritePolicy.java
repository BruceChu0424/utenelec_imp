package com.uten.imp.features.org.employee;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.employee.dto.OnboardingRequest;
import com.uten.imp.features.org.employee.dto.UpdateEmployeeRequest;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.Set;

import static com.uten.imp.common.util.Strings.isBlank;

/**
 * Enforces least-privilege writes for encrypted employee data.
 *
 * <p>The ordinary employee create/edit permissions only authorize maintaining
 * the non-sensitive employee profile. Encrypted identity/contact/bank fields
 * and compensation fields require their own explicit permissions.</p>
 */
@Component
@RequiredArgsConstructor
public class EmployeeSensitiveWritePolicy {

    public static final String PII_EDIT = "employee:pii:edit";
    public static final String COMPENSATION_EDIT = "employee:compensation:edit";

    private final SecurityContextCurrentUser currentUser;

    public void assertUpdateAllowed(UpdateEmployeeRequest request) {
        AuthUser user = requireAuthenticatedUser();
        requirePermissions(
                user.getPermissions(),
                hasPiiWrite(request),
                hasCompensationWrite(request));
    }

    public void assertOnboardingAllowed(OnboardingRequest request) {
        AuthUser user = requireAuthenticatedUser();
        OnboardingRequest.Compensation compensation =
                request == null ? null : request.compensation();
        // Identity number and phone are mandatory onboarding fields, so every
        // onboarding operation is also a PII write.
        requirePermissions(
                user.getPermissions(),
                true,
                hasCompensationWrite(compensation));
    }

    static boolean hasPiiWrite(UpdateEmployeeRequest request) {
        return request != null
                && (!isBlank(request.idNumber())
                || !isBlank(request.phone())
                || !isBlank(request.bankAccount())
                || !isBlank(request.bankBranch()));
    }

    static boolean hasCompensationWrite(UpdateEmployeeRequest request) {
        return request != null
                && (!isBlank(request.baseSalary())
                || !isBlank(request.perfSalary())
                || !isBlank(request.socialInsuranceBase())
                || !isBlank(request.socialInsuranceLocation())
                || !isBlank(request.housingFundBase())
                || !isBlank(request.allowanceStandard()));
    }

    static boolean hasCompensationWrite(OnboardingRequest.Compensation compensation) {
        return compensation != null
                && (!isBlank(compensation.baseSalary())
                || !isBlank(compensation.perfSalary())
                || !isBlank(compensation.socialInsuranceBase())
                || !isBlank(compensation.socialInsuranceLocation())
                || !isBlank(compensation.housingFundBase())
                || !isBlank(compensation.allowanceStandard()));
    }

    private AuthUser requireAuthenticatedUser() {
        return currentUser.get()
                .orElseThrow(() -> new ApiException(
                        ErrorCode.UNAUTHORIZED,
                        "写入员工资料前必须登录"));
    }

    private static void requirePermissions(
            Set<String> permissions,
            boolean writesPii,
            boolean writesCompensation) {
        Set<String> effectivePermissions =
                permissions == null ? Set.of() : permissions;
        if (writesPii && !effectivePermissions.contains(PII_EDIT)) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "缺少员工证件、联系方式或银行资料写权限");
        }
        if (writesCompensation
                && !effectivePermissions.contains(COMPENSATION_EDIT)) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "缺少员工薪资、社保、公积金或补贴资料写权限");
        }
    }
}
