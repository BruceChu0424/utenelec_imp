package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.features.auth.dto.LoginRequest;
import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.LoginRateLimiter;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InOrder;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.security.crypto.password.PasswordEncoder;

import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class LoginServiceAuditOrderingTest {

    @Mock private UserAccountRepository userRepo;
    @Mock private PasswordEncoder passwordEncoder;
    @Mock private LoginRateLimiter rateLimiter;
    @Mock private AuditService audit;
    @Mock private TokenIssuer tokenIssuer;
    @Mock private TxSessionVars tx;
    @Mock private LoginFailureRecorder failureRecorder;

    private LoginService service;
    private UserAccount user;
    private LoginRequest request;

    @BeforeEach
    void setUp() {
        when(passwordEncoder.encode("dummy-password-for-timing"))
                .thenReturn("dummy-hash");
        service = new LoginService(
                userRepo,
                passwordEncoder,
                rateLimiter,
                audit,
                tokenIssuer,
                tx,
                failureRecorder);
        user = new UserAccount();
        user.setLoginAccount("E001");
        user.setPasswordHash("password-hash");
        user.setStatus("active");
        request = new LoginRequest("E001", "correct-password");
        when(userRepo.findByLoginAccount("E001")).thenReturn(Optional.of(user));
        when(passwordEncoder.matches("correct-password", "password-hash"))
                .thenReturn(true);
    }

    @Test
    void successfulAuditIsWrittenOnlyAfterTokenIssuance() {
        TokenResponse response = new TokenResponse(
                "access", "refresh", 900, false, null);
        when(tokenIssuer.issueTokens(user)).thenReturn(response);

        assertSame(response, service.login(request, "203.0.113.9"));

        InOrder order = inOrder(userRepo, tx, tokenIssuer, audit);
        order.verify(userRepo).findByLoginAccount("E001");
        order.verify(tx).bindActor(user.getId(), user.getLoginAccount());
        order.verify(userRepo).save(user);
        order.verify(tokenIssuer).issueTokens(user);
        order.verify(audit).logExplicit(
                user.getId(),
                user.getLoginAccount(),
                "login",
                "users",
                user.getId().toString(),
                "success");
    }

    @Test
    void tokenIssuanceFailureCannotLeaveASuccessfulLoginAudit() {
        when(tokenIssuer.issueTokens(user))
                .thenThrow(new IllegalStateException("token failure"));

        assertThrows(
                IllegalStateException.class,
                () -> service.login(request, "203.0.113.9"));

        verify(audit, never()).logExplicit(
                user.getId(),
                user.getLoginAccount(),
                "login",
                "users",
                user.getId().toString(),
                "success");
    }
}
