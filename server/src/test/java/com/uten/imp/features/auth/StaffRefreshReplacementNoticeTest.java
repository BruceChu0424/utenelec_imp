package com.uten.imp.features.auth;

import com.uten.imp.common.util.HashUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.DeploymentProperties;
import com.uten.imp.features.auth.model.RefreshToken;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.RemoteAccessPolicy;
import org.junit.jupiter.api.Test;

import java.time.OffsetDateTime;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * 单设备顶号的刷新拒绝 (2026-10-27)：会话因 replaced_by_new_login 被撤销时，刷新
 * 返回 SESSION_REPLACED 与「在哪台设备登录」的完整说明，而不是含混的 UNAUTHORIZED。
 */
class StaffRefreshReplacementNoticeTest {

    @Test
    void replacedSessionRefreshReturnsSessionReplacedWithDeviceNotice() {
        UserAccountRepository users = mock(UserAccountRepository.class);
        RefreshTokenRepository tokens = mock(RefreshTokenRepository.class);
        RefreshTokenService tokenService = mock(RefreshTokenService.class);
        AuthSessionService sessions = mock(AuthSessionService.class);
        DeploymentProperties deployment = new DeploymentProperties();
        StaffRefreshTransaction transaction = new StaffRefreshTransaction(
                users, tokens, tokenService, new RemoteAccessPolicy(deployment), sessions);

        String rawToken = "kicked-by-new-login";
        UserAccount account = new UserAccount();
        account.setStatus("active");
        RefreshToken token = new RefreshToken();
        token.setUserId(account.getId());
        token.setTokenHash(HashUtil.sha256(rawToken));
        token.setExpiresAt(OffsetDateTime.now().plusHours(1));
        when(tokens.findAndLockByTokenHash(HashUtil.sha256(rawToken)))
                .thenReturn(Optional.of(token));
        identity(tokens, rawToken, token);
        when(users.findByIdForUpdate(account.getId())).thenReturn(Optional.of(account));
        when(sessions.lockAndEvaluateForRefresh(any(), any(), any())).thenReturn(
                new AuthSessionService.RefreshVerdict(
                        AuthSessionService.Verdict.REVOKED,
                        AuthSessionService.REASON_REPLACED_BY_LOGIN,
                        "Windows 客户端（BRUCE-PC）"));

        ApiException replaced = assertThrows(ApiException.class, () -> transaction.rotate(rawToken));

        assertEquals(ErrorCode.SESSION_REPLACED, replaced.getCode());
        assertEquals(401, replaced.getCode().getHttpStatus());
        assertEquals("账号已在「Windows 客户端（BRUCE-PC）」登录，本设备已自动下线", replaced.getMessage());
        verifyNoInteractions(tokenService);
    }

    @Test
    void replacedSessionWithoutDeviceNameStillExplainsReplacement() {
        UserAccountRepository users = mock(UserAccountRepository.class);
        RefreshTokenRepository tokens = mock(RefreshTokenRepository.class);
        RefreshTokenService tokenService = mock(RefreshTokenService.class);
        AuthSessionService sessions = mock(AuthSessionService.class);
        StaffRefreshTransaction transaction = new StaffRefreshTransaction(
                users, tokens, tokenService, new RemoteAccessPolicy(new DeploymentProperties()), sessions);

        String rawToken = "replaced-legacy-no-device";
        UserAccount account = new UserAccount();
        account.setStatus("active");
        RefreshToken token = new RefreshToken();
        token.setUserId(account.getId());
        token.setTokenHash(HashUtil.sha256(rawToken));
        token.setExpiresAt(OffsetDateTime.now().plusHours(1));
        when(tokens.findAndLockByTokenHash(HashUtil.sha256(rawToken)))
                .thenReturn(Optional.of(token));
        identity(tokens, rawToken, token);
        when(users.findByIdForUpdate(account.getId())).thenReturn(Optional.of(account));
        when(sessions.lockAndEvaluateForRefresh(any(), any(), any())).thenReturn(
                new AuthSessionService.RefreshVerdict(
                        AuthSessionService.Verdict.REVOKED,
                        AuthSessionService.REASON_REPLACED_BY_LOGIN,
                        null));

        ApiException replaced = assertThrows(ApiException.class, () -> transaction.rotate(rawToken));

        assertEquals(ErrorCode.SESSION_REPLACED, replaced.getCode());
        assertTrue(replaced.getMessage().contains("其他设备"));
        verifyNoInteractions(tokenService);
    }

    private static void identity(RefreshTokenRepository tokens, String raw, RefreshToken token) {
        var identity = mock(RefreshTokenRepository.Identity.class);
        when(identity.getUserId()).thenReturn(token.getUserId());
        when(identity.getSessionId()).thenReturn(token.getSessionId());
        when(tokens.findIdentityByTokenHash(HashUtil.sha256(raw))).thenReturn(Optional.of(identity));
    }
}
