package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import org.junit.jupiter.params.provider.NullAndEmptySource;
import org.junit.jupiter.params.provider.ValueSource;

import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class PasswordPolicyTest {

    private final PasswordPolicy policy = new PasswordPolicy();

    @ParameterizedTest
    @MethodSource("nonBlankPasswords")
    void acceptsAnyNonBlankPassword(String password) {
        assertDoesNotThrow(() -> policy.validate(password));
    }

    private static Stream<String> nonBlankPasswords() {
        return Stream.of("1", "a", "中", "!", " x ", "x".repeat(129), "中".repeat(4096));
    }

    @ParameterizedTest
    @NullAndEmptySource
    @ValueSource(strings = {" ", "\t\r\n", "\u3000"})
    void rejectsMissingAndWhitespaceOnlyPasswords(String password) {
        ApiException error = assertThrows(ApiException.class, () -> policy.validate(password));
        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
    }
}
