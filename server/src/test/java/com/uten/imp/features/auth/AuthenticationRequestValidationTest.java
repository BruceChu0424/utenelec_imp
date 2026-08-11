package com.uten.imp.features.auth;

import com.uten.imp.features.auth.dto.ChangePasswordRequest;
import com.uten.imp.features.auth.dto.LoginRequest;
import com.uten.imp.features.auth.dto.RefreshRequest;
import com.uten.imp.features.auth.dto.VerifyPasswordRequest;
import com.uten.imp.features.visitor.dto.VisitorScanDto;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class AuthenticationRequestValidationTest {

    private final Validator validator = Validation.buildDefaultValidatorFactory().getValidator();

    @Test
    void authenticationSecretsHaveExplicitLengthBounds() {
        assertFalse(validator.validate(new LoginRequest(
                "a".repeat(129), "secret")).isEmpty());
        assertFalse(validator.validate(new LoginRequest(
                "account", "x".repeat(129))).isEmpty());
        assertFalse(validator.validate(new RefreshRequest("x".repeat(513))).isEmpty());
        assertFalse(validator.validate(new ChangePasswordRequest(
                "old", "x".repeat(129))).isEmpty());
        assertFalse(validator.validate(new VerifyPasswordRequest(
                "x".repeat(129))).isEmpty());
    }

    @Test
    void gateInputCapsQrTokensAndRequiresSixDigitPasscodes() {
        assertFalse(validator.validate(new VisitorScanDto.VisitorVerifyRequest(
                "x".repeat(1_025), null)).isEmpty());
        assertFalse(validator.validate(new VisitorScanDto.VisitorVerifyRequest(
                null, "12345x")).isEmpty());
        assertTrue(validator.validate(new VisitorScanDto.VisitorVerifyRequest(
                null, "123456")).isEmpty());
    }
}
