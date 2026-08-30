package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.DeploymentProperties;
import com.uten.imp.features.auth.dto.LoginRequest;
import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.LoginRateLimiter;
import com.uten.imp.security.RemoteAccessPolicy;
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
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
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
    private RemoteAccessPolicy remoteAccessPolicy;

    @BeforeEach
    void setUp() {
        when(passwordEncoder.encode("dummy-password-for-timing"))
                .thenReturn("dummy-hash");
        DeploymentProperties deployment = new DeploymentProperties();
        deployment.setSite("cloud");
        remoteAccessPolicy = new RemoteAccessPolicy(deployment);
        service = new LoginService(
                userRepo,
                passwordEncoder,
                rateLimiter,
                audit,
                tokenIssuer,
                tx,
                failureRecorder,
                remoteAccessPolicy);
        user = new UserAccount();
        user.setLoginAccount("E001");
        user.setPasswordHash("password-hash");
        user.setStatus("active");
        user.setRemoteAccess(true);
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
        order.verify(audit).logCommitted(
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

        verify(audit, never()).logCommitted(
                user.getId(),
                user.getLoginAccount(),
                "login",
                "users",
                user.getId().toString(),
                "success");
    }

    @Test
    void cloudDenialOccursAfterCredentialAndStatusChecksButBeforeIssuance() {
        user.setRemoteAccess(false);

        ApiException denied = assertThrows(
                ApiException.class,
                () -> service.login(request, "203.0.113.9"));

        assertEquals(ErrorCode.REMOTE_ACCESS_DENIED, denied.getCode());
        assertNull(user.getLastLoginAt());
        verify(userRepo, never()).save(user);
        verify(tokenIssuer, never()).issueTokens(user);
        verify(audit).logExplicit(
                user.getId(), user.getLoginAccount(), "login_failed",
                "users", user.getId().toString(), "remote_access_denied");
    }

    @Test
    void wrongPasswordDoesNotRevealRemoteAuthorizationState() {
        user.setRemoteAccess(false);
        when(passwordEncoder.matches("correct-password", "password-hash"))
                .thenReturn(false);

        ApiException denied = assertThrows(
                ApiException.class,
                () -> service.login(request, "203.0.113.9"));

        assertEquals(ErrorCode.BAD_CREDENTIALS, denied.getCode());
        verify(tokenIssuer, never()).issueTokens(user);
    }

    @Test
    void disabledStatusTakesPrecedenceOverRemoteAuthorization() {
        user.setStatus("disabled");
        user.setRemoteAccess(false);

        ApiException denied = assertThrows(
                ApiException.class,
                () -> service.login(request, "203.0.113.9"));

        assertEquals(ErrorCode.ACCOUNT_DISABLED, denied.getCode());
        verify(tokenIssuer, never()).issueTokens(user);
    }

    @Test
    void expiredTemporaryPasswordIsRejectedWithExplicitAudit() {
        // V297：管理员设置的临时密码 72h 过期后不可再登录（密码正确也拒绝）
        user.setMustChangePassword(true);
        user.setTempPasswordExpiresAt(
                java.time.OffsetDateTime.now().minusMinutes(1));

        ApiException denied = assertThrows(
                ApiException.class,
                () -> service.login(request, "203.0.113.9"));

        assertEquals(ErrorCode.UNAUTHORIZED, denied.getCode());
        verify(tokenIssuer, never()).issueTokens(user);
        verify(userRepo, never()).save(user);
        verify(audit).logExplicit(
                user.getId(), user.getLoginAccount(), "login_failed",
                "users", user.getId().toString(), "temporary_password_expired");
    }

    @Test
    void unexpiredTemporaryPasswordCanStillLogIn() {
        user.setMustChangePassword(true);
        user.setTempPasswordExpiresAt(
                java.time.OffsetDateTime.now().plusHours(1));
        TokenResponse response = new TokenResponse(
                "access", "refresh", 900, true, null);
        when(tokenIssuer.issueTokens(user)).thenReturn(response);

        assertSame(response, service.login(request, "203.0.113.9"));
    }
}
