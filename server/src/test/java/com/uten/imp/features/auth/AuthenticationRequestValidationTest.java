package com.uten.imp.features.auth;

import com.uten.imp.features.auth.dto.ChangePasswordRequest;
import com.uten.imp.features.auth.dto.LoginRequest;
import com.uten.imp.features.auth.dto.RefreshRequest;
import com.uten.imp.features.auth.dto.StepUpRequest;
import com.uten.imp.features.visitor.dto.VisitorScanDto;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import org.junit.jupiter.params.provider.NullAndEmptySource;
import org.junit.jupiter.params.provider.ValueSource;

import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class AuthenticationRequestValidationTest {

    private final Validator validator = Validation.buildDefaultValidatorFactory().getValidator();

    @Test
    void accountIdentifiersAndRefreshTokensKeepTheirLengthBounds() {
        assertFalse(validator.validate(new LoginRequest(
                "a".repeat(129), "secret")).isEmpty());
        assertFalse(validator.validate(new RefreshRequest("x".repeat(513))).isEmpty());
    }

    @ParameterizedTest
    @MethodSource("nonBlankPasswords")
    void allPasswordInputsAcceptNonBlankValuesWithoutLengthOrCharacterRules(String password) {
        assertTrue(validator.validate(new LoginRequest("account", password)).isEmpty());
        assertTrue(validator.validate(new ChangePasswordRequest(password, password)).isEmpty());
        assertTrue(validator.validate(new StepUpRequest(password)).isEmpty());
    }

    private static Stream<String> nonBlankPasswords() {
        return Stream.of("1", "a", "中", "!", " x ", "x".repeat(129), "中".repeat(4096));
    }

    @ParameterizedTest
    @NullAndEmptySource
    @ValueSource(strings = {" ", "\t\r\n"})
    void allPasswordInputsStillRejectBlankValues(String password) {
        assertFalse(validator.validate(new LoginRequest("account", password)).isEmpty());
        assertFalse(validator.validate(new ChangePasswordRequest(password, "new")).isEmpty());
        assertFalse(validator.validate(new ChangePasswordRequest("old", password)).isEmpty());
        assertFalse(validator.validate(new StepUpRequest(password)).isEmpty());
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
