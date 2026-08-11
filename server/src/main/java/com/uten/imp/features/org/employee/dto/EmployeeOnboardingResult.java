package com.uten.imp.features.org.employee.dto;

/**
 * One-time onboarding credential delivery.
 *
 * <p>The temporary password is returned only by the create response and is
 * never persisted in plaintext. The client must discard it when the dialog is
 * closed.  {@code loginAccount} carries the actual login identifier (默认手机号)
 * so the credential dialog can show exactly what the new hire types at login.
 */
public record EmployeeOnboardingResult(
        EmployeeDetail employee,
        String temporaryPassword,
        String loginAccount
) {
}
