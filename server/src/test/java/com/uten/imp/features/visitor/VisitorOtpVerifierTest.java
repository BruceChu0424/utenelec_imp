package com.uten.imp.features.visitor;

import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.lang.reflect.Method;
import java.time.OffsetDateTime;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class VisitorOtpVerifierTest {

    @Mock
    private VisitorSmsCodeRepository repository;
    @Mock
    private TxSessionVars tx;

    private VisitorOtpVerifier verifier;

    @BeforeEach
    void setUp() {
        verifier = new VisitorOtpVerifier(repository, tx);
    }

    @Test
    void transactionIsIndependentFromTheThrowingAuthenticationFlow()
            throws Exception {
        Method method = VisitorOtpVerifier.class
                .getMethod("verify", String.class, String.class);
        Transactional transactional = method.getAnnotation(Transactional.class);

        assertNotNull(transactional);
        assertEquals(Propagation.REQUIRES_NEW, transactional.propagation());
    }

    @Test
    void wrongCodeReturnsNormallySoAttemptIncrementCanCommit() {
        VisitorSmsCode row = activeCode(0);
        when(repository.findTopByPhoneAndConsumedAtIsNullOrderByCreatedAtDesc(
                "13800138000")).thenReturn(Optional.of(row));
        when(tx.hmac(VisitorSmsService.otpMacInput(
                "13800138000", "login", "000000"))).thenReturn("wrong");

        VisitorOtpVerifier.Result result =
                verifier.verify("13800138000", "000000");

        assertEquals(VisitorOtpVerifier.Result.INVALID, result);
        assertEquals(1, row.getAttempts());
        assertNull(row.getConsumedAt());
        verify(repository).save(row);
    }

    @Test
    void finalAllowedWrongAttemptConsumesTheCode() {
        VisitorSmsCode row = activeCode(4);
        when(repository.findTopByPhoneAndConsumedAtIsNullOrderByCreatedAtDesc(
                "13800138000")).thenReturn(Optional.of(row));
        when(tx.hmac(VisitorSmsService.otpMacInput(
                "13800138000", "login", "000000"))).thenReturn("wrong");

        VisitorOtpVerifier.Result result =
                verifier.verify("13800138000", "000000");

        assertEquals(VisitorOtpVerifier.Result.INVALID, result);
        assertEquals(5, row.getAttempts());
        assertNotNull(row.getConsumedAt());
    }

    @Test
    void correctCodeIsConsumedExactlyOnce() {
        VisitorSmsCode row = activeCode(0);
        when(repository.findTopByPhoneAndConsumedAtIsNullOrderByCreatedAtDesc(
                "13800138000")).thenReturn(Optional.of(row));
        when(tx.hmac(VisitorSmsService.otpMacInput(
                "13800138000", "login", "123456"))).thenReturn("correct-mac");

        VisitorOtpVerifier.Result result =
                verifier.verify("13800138000", "123456");

        assertEquals(VisitorOtpVerifier.Result.VALID, result);
        assertEquals(1, row.getAttempts());
        assertNotNull(row.getConsumedAt());
    }

    private VisitorSmsCode activeCode(int attempts) {
        VisitorSmsCode row = new VisitorSmsCode();
        row.setScene("login");
        row.setCodeHash("correct-mac");
        row.setAttempts(attempts);
        row.setExpiresAt(OffsetDateTime.now().plusMinutes(5));
        return row;
    }
}
