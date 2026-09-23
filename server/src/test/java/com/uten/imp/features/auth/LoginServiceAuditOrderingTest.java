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

import java.time.OffsetDateTime;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 登录编排 (ADR-110): 事务外校验密码, 锁定期不校验真实密码且与错密码同码同文案,
 * 成功态交给短写事务 {@link StaffLoginTransaction}。
 */
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
        DeploymentProperties deployment = new DeploymentProperties();
        deployment.setSite("cloud");
        RemoteAccessPolicy remoteAccessPolicy = new RemoteAccessPolicy(deployment);
        service = new LoginService(
                userRepo,
                passwordEncoder,
                rateLimiter,
                audit,
                failureRecorder,
                remoteAccessPolicy,
                new StaffLoginTransaction(userRepo, tokenIssuer, audit, tx));
        user = new UserAccount();
        user.setLoginAccount("E001");
        user.setPasswordHash("password-hash");
        user.setStatus("active");
        user.setRemoteAccess(true);
        request = new LoginRequest("E001", "correct-password");
        org.mockito.Mockito.lenient().when(userRepo.findByLoginAccount("E001")).thenReturn(Optional.of(user));
    }

    private void passwordIsCorrect() {
        when(passwordEncoder.matches("correct-password", "password-hash")).thenReturn(true);
    }

    private void rowLockSeesSameAccount() {
        when(userRepo.findByIdForUpdate(user.getId())).thenReturn(Optional.of(user));
    }

    @Test
    void successfulAuditIsWrittenOnlyAfterTokenIssuance() {
        passwordIsCorrect();
        rowLockSeesSameAccount();
        TokenResponse response = new TokenResponse(
                "access", "refresh", 900, false, null);
        when(tokenIssuer.issueTokens(user)).thenReturn(response);

        assertSame(response, service.login(request, "203.0.113.9"));

        InOrder order = inOrder(userRepo, passwordEncoder, tx, tokenIssuer, audit);
        order.verify(userRepo).findByLoginAccount("E001");
        // 密码在读快照之后、行锁写事务之前校验 (事务外)
        order.verify(passwordEncoder).matches("correct-password", "password-hash");
        order.verify(userRepo).findByIdForUpdate(user.getId());
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
        passwordIsCorrect();
        rowLockSeesSameAccount();
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
    void passwordChangedBetweenVerificationAndWriteIsTreatedAsWrongPassword() {
        passwordIsCorrect();
        UserAccount changed = new UserAccount();
        changed.setId(user.getId());
        changed.setLoginAccount("E001");
        changed.setPasswordHash("new-hash-after-reset");
        changed.setStatus("active");
        when(userRepo.findByIdForUpdate(user.getId())).thenReturn(Optional.of(changed));

        ApiException denied = assertThrows(ApiException.class,
                () -> service.login(request, "203.0.113.9"));

        assertEquals(ErrorCode.BAD_CREDENTIALS, denied.getCode());
        verify(tokenIssuer, never()).issueTokens(any());
    }

    @Test
    void lockedAccountCorrectPasswordReturnsSameCodeAsWrongPassword() {
        user.setStatus("locked");
        user.setLockedUntil(OffsetDateTime.now().plusMinutes(10));

        ApiException correct = assertThrows(ApiException.class,
                () -> service.login(request, "203.0.113.9"));
        ApiException wrong = assertThrows(ApiException.class,
                () -> service.login(new LoginRequest("E001", "wrong-password"), "203.0.113.9"));

        // security-01: 锁定期内对/错密码响应完全一致, 且从不校验真实密码哈希
        assertEquals(ErrorCode.BAD_CREDENTIALS, correct.getCode());
        assertEquals(correct.getCode(), wrong.getCode());
        assertEquals(correct.getMessage(), wrong.getMessage());
        assertEquals("账号或密码错误，多次失败将临时锁定", correct.getMessage());
        verify(passwordEncoder, never()).matches(anyString(), org.mockito.ArgumentMatchers.eq("password-hash"));
        verify(passwordEncoder).matches("correct-password", "dummy-hash");
        verify(passwordEncoder).matches("wrong-password", "dummy-hash");
        // 锁定期的每次尝试继续计数 (顺延锁定)
        verify(failureRecorder, org.mockito.Mockito.times(2))
                .record(user.getId(), "E001", "attempt_while_locked");
        verify(tokenIssuer, never()).issueTokens(any());
    }

    @Test
    void unknownAccountRunsDummyHashAndReturnsTheSameCode() {
        when(userRepo.findByLoginAccount("ghost")).thenReturn(Optional.empty());

        ApiException denied = assertThrows(ApiException.class,
                () -> service.login(new LoginRequest("ghost", "whatever"), "203.0.113.9"));

        assertEquals(ErrorCode.BAD_CREDENTIALS, denied.getCode());
        verify(passwordEncoder).matches("whatever", "dummy-hash");
    }

    @Test
    void cloudDenialOccursAfterCredentialAndStatusChecksButBeforeIssuance() {
        passwordIsCorrect();
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
        verify(failureRecorder).record(user.getId(), "E001", "bad_password");
    }

    @Test
    void disabledStatusTakesPrecedenceOverRemoteAuthorization() {
        passwordIsCorrect();
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
        passwordIsCorrect();
        user.setMustChangePassword(true);
        user.setTempPasswordExpiresAt(OffsetDateTime.now().minusMinutes(1));

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
        passwordIsCorrect();
        rowLockSeesSameAccount();
        user.setMustChangePassword(true);
        user.setTempPasswordExpiresAt(OffsetDateTime.now().plusHours(1));
        TokenResponse response = new TokenResponse(
                "access", "refresh", 900, true, null);
        when(tokenIssuer.issueTokens(user)).thenReturn(response);

        assertSame(response, service.login(request, "203.0.113.9"));
    }
}
