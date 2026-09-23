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
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class StaffRefreshRemoteAccessTest {

    @Test
    void cloudDenialHappensBeforeRefreshTokenRotation() {
        UserAccountRepository users = mock(UserAccountRepository.class);
        RefreshTokenRepository tokens = mock(RefreshTokenRepository.class);
        RefreshTokenService tokenService = mock(RefreshTokenService.class);
        DeploymentProperties deployment = new DeploymentProperties();
        deployment.setSite("cloud");
        AuthSessionService sessions = mock(AuthSessionService.class);
        when(sessions.lockAndEvaluateForRefresh(any(), any(), any()))
                .thenReturn(AuthSessionService.Verdict.ACTIVE);
        StaffRefreshTransaction transaction = new StaffRefreshTransaction(
                users,
                tokens,
                tokenService,
                new RemoteAccessPolicy(deployment),
                sessions);

        String rawToken = "valid-refresh-token";
        UserAccount account = new UserAccount();
        account.setStatus("active");
        account.setRemoteAccess(false);
        RefreshToken token = new RefreshToken();
        token.setUserId(account.getId());
        token.setTokenHash(HashUtil.sha256(rawToken));
        token.setExpiresAt(OffsetDateTime.now().plusHours(1));
        token.setDeviceInfo("test-device");
        when(tokens.findAndLockByTokenHash(HashUtil.sha256(rawToken)))
                .thenReturn(Optional.of(token));
        when(users.findById(account.getId())).thenReturn(Optional.of(account));

        ApiException denied = assertThrows(
                ApiException.class,
                () -> transaction.rotate(rawToken));

        assertEquals(ErrorCode.REMOTE_ACCESS_DENIED, denied.getCode());
        verifyNoInteractions(tokenService);
        verify(tokens, never()).findByTokenHash(org.mockito.ArgumentMatchers.anyString());
    }

    @Test
    void revokedFamilyFromRemoteToggleKeepsExplicitCloudDenial() {
        UserAccountRepository users = mock(UserAccountRepository.class);
        RefreshTokenRepository tokens = mock(RefreshTokenRepository.class);
        RefreshTokenService tokenService = mock(RefreshTokenService.class);
        DeploymentProperties deployment = new DeploymentProperties();
        deployment.setSite("cloud");
        // 远程访问开关同时吊销了会话: 仍返回明确的「未授权外网访问」, 不当成令牌被盗。
        AuthSessionService sessions = mock(AuthSessionService.class);
        when(sessions.lockAndEvaluateForRefresh(any(), any(), any()))
                .thenReturn(AuthSessionService.Verdict.REVOKED);
        StaffRefreshTransaction transaction = new StaffRefreshTransaction(
                users, tokens, tokenService, new RemoteAccessPolicy(deployment), sessions);

        String rawToken = "revoked-by-remote-toggle";
        UserAccount account = new UserAccount();
        account.setStatus("active");
        account.setRemoteAccess(false);
        RefreshToken token = new RefreshToken();
        token.setUserId(account.getId());
        token.setTokenHash(HashUtil.sha256(rawToken));
        token.setExpiresAt(OffsetDateTime.now().plusHours(1));
        token.setRevokedAt(OffsetDateTime.now());
        when(tokens.findAndLockByTokenHash(HashUtil.sha256(rawToken)))
                .thenReturn(Optional.of(token));
        when(users.findById(account.getId())).thenReturn(Optional.of(account));

        ApiException denied = assertThrows(ApiException.class, () -> transaction.rotate(rawToken));

        assertEquals(ErrorCode.REMOTE_ACCESS_DENIED, denied.getCode());
        verifyNoInteractions(tokenService);
    }
}
