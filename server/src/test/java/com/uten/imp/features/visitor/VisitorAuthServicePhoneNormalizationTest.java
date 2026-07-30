package com.uten.imp.features.visitor;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.config.props.SmsProperties;
import com.uten.imp.features.org.employee.EmployeeSensitiveRepository;
import com.uten.imp.security.JwtService;
import com.uten.imp.security.LoginRateLimiter;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class VisitorAuthServicePhoneNormalizationTest {

    private VisitorSmsService smsService;
    private LoginRateLimiter rateLimiter;
    private VisitorAuthService authService;

    @BeforeEach
    void setUp() {
        smsService = mock(VisitorSmsService.class);
        rateLimiter = mock(LoginRateLimiter.class);
        authService = new VisitorAuthService(
                mock(VisitorAccountRepository.class),
                smsService,
                mock(VisitorRefreshTokenService.class),
                mock(VisitorRefreshTokenRepository.class),
                mock(VisitorRefreshTransaction.class),
                mock(VisitorRefreshCompromiseService.class),
                mock(EmployeeSensitiveRepository.class),
                mock(JwtService.class),
                mock(TxSessionVars.class),
                new SmsProperties(),
                mock(AuditService.class),
                rateLimiter);
    }

    @Test
    void formattedMainlandPhoneIsCanonicalBeforeRateLimitAndSmsIssuance() {
        when(smsService.send("13800138000", "login")).thenReturn("123456");
        when(smsService.codeTtlSeconds()).thenReturn(300);

        var response =
                authService.sendCode("+86 (138) 0013-8000", "203.0.113.40");

        assertEquals(300, response.expiresInSeconds());
        verify(rateLimiter).check(
                LoginRateLimiter.Scope.VISITOR_SEND_CODE,
                "203.0.113.40",
                "13800138000");
        verify(smsService).send("13800138000", "login");
    }

    @Test
    void nonMainlandPhoneIsRejectedBeforeRateLimitOrSmsIssuance() {
        assertThrows(
                ApiException.class,
                () -> authService.sendCode("12800138000", "203.0.113.41"));

        verify(rateLimiter, never()).check(
                LoginRateLimiter.Scope.VISITOR_SEND_CODE,
                "203.0.113.41",
                "12800138000");
        verify(smsService, never()).send("12800138000", "login");
    }
}
