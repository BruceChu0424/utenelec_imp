package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.auth.dto.ChangePasswordRequest;
import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.features.auth.model.PasswordHistoryRepository;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.PasswordPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.mockito.InOrder;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.security.crypto.password.PasswordEncoder;

import java.lang.reflect.Method;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 改密三段式 (ADR-110): 原密码走共享失败计数的再认证校验, 新哈希在事务外算好,
 * 短写事务加行锁复核后才落库、吊销全部旧会话并开新会话。
 */
class PasswordAccessInvalidationTest {

    private final UserAccountRepository users = mock(UserAccountRepository.class);
    private final PasswordHistoryRepository history = mock(PasswordHistoryRepository.class);
    private final RefreshTokenRepository refreshTokens = mock(RefreshTokenRepository.class);
    private final PasswordEncoder encoder = mock(PasswordEncoder.class);
    private final SystemSettingsService settings = mock(SystemSettingsService.class);
    private final SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
    private final AuditService audit = mock(AuditService.class);
    private final TokenIssuer tokenIssuer = mock(TokenIssuer.class);
    private final AuthSessionService sessions = mock(AuthSessionService.class);
    private final StepUpService stepUp = mock(StepUpService.class);
    private final UUID sessionId = UUID.randomUUID();

    private PasswordService service() {
        PasswordChangeTransaction transaction = new PasswordChangeTransaction(
                users, history, refreshTokens, sessions, tokenIssuer, audit, mock(TxSessionVars.class));
        return new PasswordService(users, history, encoder, new PasswordPolicy(settings),
                settings, currentUser, stepUp, transaction);
    }

    private UserAccount currentAccount() {
        UserAccount user = new UserAccount();
        user.setLoginAccount("E1001");
        user.setPasswordHash("old-hash");
        user.setMustChangePassword(true);
        AuthUser principal = new AuthUser(user.getId(), UUID.randomUUID(), "E1001", Set.of(),
                true, true, false, false, null, sessionId);
        when(currentUser.get()).thenReturn(Optional.of(principal));
        when(settings.readInt(SystemSettingKey.PASSWORD_MIN_LENGTH)).thenReturn(8);
        when(settings.readInt(SystemSettingKey.PASSWORD_HISTORY_SIZE)).thenReturn(5);
        return user;
    }

    @Test
    void passwordChangeHashesOutsideTheWriteTransactionThenBumpsRevokesAndReissues() {
        UserAccount user = currentAccount();
        UserAccount refreshedUser = new UserAccount();
        refreshedUser.setId(user.getId());
        refreshedUser.setLoginAccount("E1001");
        refreshedUser.setPasswordHash("new-hash");
        refreshedUser.setAuthVersion(1);
        TokenResponse replacement = new TokenResponse("access", "refresh", 900, false, null);
        when(users.findById(user.getId()))
                .thenReturn(Optional.of(user))
                .thenReturn(Optional.of(refreshedUser));
        when(users.findByIdForUpdate(user.getId())).thenReturn(Optional.of(user));
        when(history.findRecent(user.getId(), 5)).thenReturn(List.of());
        when(encoder.encode("new-password-1")).thenReturn("new-hash");
        when(users.bumpAuthVersion(user.getId())).thenReturn(1);
        when(tokenIssuer.issueTokensAfterPasswordChange(refreshedUser)).thenReturn(replacement);

        TokenResponse actual = service().changePassword(
                new ChangePasswordRequest("old-password", "new-password-1"));

        assertEquals(replacement, actual);
        assertEquals("new-hash", user.getPasswordHash());
        assertFalse(user.isMustChangePassword());
        assertNotNull(user.getLastPasswordChangedAt());
        InOrder order = inOrder(stepUp, encoder, users, refreshTokens, sessions, tokenIssuer);
        // 原密码经共享失败计数的再认证校验 (错了 422, 连错暂停并踢会话)
        order.verify(stepUp).verifyPassword(user.getId(), "E1001", "old-password", sessionId,
                StepUpService.Purpose.CHANGE_PASSWORD);
        order.verify(encoder).encode("new-password-1");
        order.verify(users).findByIdForUpdate(user.getId());
        order.verify(users).save(user);
        order.verify(users).bumpAuthVersion(user.getId());
        order.verify(refreshTokens).revokeAllByUserId(user.getId());
        order.verify(sessions).revokeAllForUser(user.getId(), AuthSessionService.REASON_PASSWORD_CHANGED);
        order.verify(tokenIssuer).issueTokensAfterPasswordChange(refreshedUser);
    }

    @Test
    void wrongOldPasswordStopsBeforeAnyHashingOrWrite() {
        UserAccount user = currentAccount();
        when(users.findById(user.getId())).thenReturn(Optional.of(user));
        org.mockito.Mockito.doThrow(new ApiException(ErrorCode.REAUTH_FAILED, "原密码不正确"))
                .when(stepUp).verifyPassword(any(), any(), any(), any(), any());

        ApiException error = assertThrows(ApiException.class, () -> service().changePassword(
                new ChangePasswordRequest("bad-old", "new-password-1")));

        // 422 而不是 401: 前端不会把它当登录过期去刷新重放, 一次输错只算一次。
        assertEquals(ErrorCode.REAUTH_FAILED, error.getCode());
        assertEquals(422, error.getCode().getHttpStatus());
        verify(encoder, never()).encode(any());
        verify(users, never()).findByIdForUpdate(any());
    }

    @Test
    void passwordChangedConcurrentlyIsAConflictNotASilentOverwrite() {
        UserAccount user = currentAccount();
        UserAccount changedElsewhere = new UserAccount();
        changedElsewhere.setId(user.getId());
        changedElsewhere.setPasswordHash("reset-by-admin");
        when(users.findById(user.getId())).thenReturn(Optional.of(user));
        when(users.findByIdForUpdate(user.getId())).thenReturn(Optional.of(changedElsewhere));
        when(history.findRecent(user.getId(), 5)).thenReturn(List.of());
        when(encoder.encode("new-password-1")).thenReturn("new-hash");

        ApiException error = assertThrows(ApiException.class, () -> service().changePassword(
                new ChangePasswordRequest("old-password", "new-password-1")));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        verify(users, never()).save(any());
        verify(sessions, never()).revokeAllForUser(any(), any());
    }

    @Test
    void nativeAuthVersionBumpFlushesPendingPasswordStateAndClearsPersistenceContext()
            throws Exception {
        Method bump = UserAccountRepository.class.getMethod(
                "bumpAuthVersion",
                UUID.class);
        Modifying modifying = bump.getAnnotation(Modifying.class);

        assertNotNull(modifying);
        assertTrue(modifying.flushAutomatically());
        assertTrue(modifying.clearAutomatically());
    }
}
