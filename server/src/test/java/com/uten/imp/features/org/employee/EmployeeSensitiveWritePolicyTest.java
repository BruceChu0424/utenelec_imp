package com.uten.imp.features.org.employee;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.employee.dto.OnboardingRequest;
import com.uten.imp.features.org.employee.dto.UpdateEmployeeRequest;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class EmployeeSensitiveWritePolicyTest {

    private SecurityContextCurrentUser currentUser;
    private EmployeeSensitiveWritePolicy policy;

    @BeforeEach
    void setUp() {
        currentUser = mock(SecurityContextCurrentUser.class);
        policy = new EmployeeSensitiveWritePolicy(currentUser);
    }

    @Test
    void rejectsUnauthenticatedWritesFailClosed() {
        when(currentUser.get()).thenReturn(Optional.empty());

        ApiException error = assertThrows(
                ApiException.class,
                () -> policy.assertUpdateAllowed(update(null, null, null, null,
                        null, null, null, null, null, null)));

        assertEquals(ErrorCode.UNAUTHORIZED, error.getCode());
        ApiException onboardingError = assertThrows(
                ApiException.class,
                () -> policy.assertOnboardingAllowed(onboarding(null)));
        assertEquals(ErrorCode.UNAUTHORIZED, onboardingError.getCode());
    }

    @Test
    void blankSensitiveFieldsDoNotRequireSensitivePermissions() {
        authenticateWith();

        assertDoesNotThrow(() -> policy.assertUpdateAllowed(
                update("  ", "", null, "\t",
                        "", " ", null, null, "", "\n")));
    }

    @Test
    void piiAndCompensationPermissionsAreIndependent() {
        UpdateEmployeeRequest piiUpdate =
                update("110101199001010011", null, null, null,
                        null, null, null, null, null, null);
        UpdateEmployeeRequest compensationUpdate =
                update(null, null, null, null,
                        "12000", null, null, null, null, null);

        authenticateWith(EmployeeSensitiveWritePolicy.COMPENSATION_EDIT);
        assertForbidden(() -> policy.assertUpdateAllowed(piiUpdate));

        authenticateWith(EmployeeSensitiveWritePolicy.PII_EDIT);
        assertForbidden(() -> policy.assertUpdateAllowed(compensationUpdate));

        authenticateWith(EmployeeSensitiveWritePolicy.PII_EDIT);
        assertDoesNotThrow(() -> policy.assertUpdateAllowed(piiUpdate));

        authenticateWith(EmployeeSensitiveWritePolicy.COMPENSATION_EDIT);
        assertDoesNotThrow(() -> policy.assertUpdateAllowed(compensationUpdate));
    }

    @Test
    void updateWithBothSensitiveGroupsRequiresBothPermissions() {
        UpdateEmployeeRequest both =
                update(null, "13800138000", null, null,
                        null, null, "12000", null, null, null);

        authenticateWith(EmployeeSensitiveWritePolicy.PII_EDIT);
        assertForbidden(() -> policy.assertUpdateAllowed(both));

        authenticateWith(
                EmployeeSensitiveWritePolicy.PII_EDIT,
                EmployeeSensitiveWritePolicy.COMPENSATION_EDIT);
        assertDoesNotThrow(() -> policy.assertUpdateAllowed(both));
    }

    @Test
    void onboardingAlwaysRequiresPiiButBankFieldsDoNotRequireCompensation() {
        OnboardingRequest withoutCompensation = onboarding(null);
        OnboardingRequest bankOnly = onboarding(new OnboardingRequest.Compensation(
                null, null, "6222020200000000000", "Test branch",
                null, null, null, null));

        authenticateWith();
        assertForbidden(() -> policy.assertOnboardingAllowed(withoutCompensation));

        authenticateWith(EmployeeSensitiveWritePolicy.PII_EDIT);
        assertDoesNotThrow(
                () -> policy.assertOnboardingAllowed(withoutCompensation));
        assertDoesNotThrow(() -> policy.assertOnboardingAllowed(bankOnly));
    }

    @Test
    void onboardingOnlyRequiresCompensationPermissionWhenSalaryDataIsSubmitted() {
        OnboardingRequest salary = onboarding(new OnboardingRequest.Compensation(
                "12000", null, null, null,
                null, null, null, null));
        OnboardingRequest insuranceLocation =
                onboarding(new OnboardingRequest.Compensation(
                        null, null, null, null,
                        null, "Shanghai", null, null));

        authenticateWith(EmployeeSensitiveWritePolicy.PII_EDIT);
        assertForbidden(() -> policy.assertOnboardingAllowed(salary));
        assertForbidden(() -> policy.assertOnboardingAllowed(insuranceLocation));

        authenticateWith(
                EmployeeSensitiveWritePolicy.PII_EDIT,
                EmployeeSensitiveWritePolicy.COMPENSATION_EDIT);
        assertDoesNotThrow(() -> policy.assertOnboardingAllowed(salary));
        assertDoesNotThrow(
                () -> policy.assertOnboardingAllowed(insuranceLocation));
    }

    private void authenticateWith(String... permissions) {
        AuthUser user = new AuthUser(
                UUID.randomUUID(),
                UUID.randomUUID(),
                "test-user",
                Set.of(),
                Set.of(permissions),
                false,
                true,
                false);
        when(currentUser.get()).thenReturn(Optional.of(user));
    }

    private void assertForbidden(Runnable action) {
        ApiException error = assertThrows(ApiException.class, action::run);
        assertEquals(ErrorCode.FORBIDDEN, error.getCode());
    }

    private static OnboardingRequest onboarding(
            OnboardingRequest.Compensation compensation) {
        return new OnboardingRequest(
                null,
                null,
                compensation,
                null,
                null,
                null,
                null,
                null);
    }

    private static UpdateEmployeeRequest update(
            String idNumber,
            String phone,
            String bankAccount,
            String bankBranch,
            String baseSalary,
            String perfSalary,
            String socialInsuranceBase,
            String housingFundBase,
            String allowanceStandard,
            String socialInsuranceLocation) {
        return new UpdateEmployeeRequest(
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                idNumber,
                phone,
                bankAccount,
                bankBranch,
                baseSalary,
                perfSalary,
                socialInsuranceBase,
                housingFundBase,
                allowanceStandard,
                socialInsuranceLocation,
                null,
                null);
    }
}
