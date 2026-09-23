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
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * ADR-110: 只有「已被轮换出新令牌」的旧令牌再次出现才是被盗重放 (吊销全部会话 + 安全事件)。
 * 改登录手机号、权限变更等整族作废的令牌在会话仍有效时出现, 是普通 401 (回登录页), 不误报重放。
 */
class StaffRefreshReuseClassificationTest {

    private final UserAccountRepository users = mock(UserAccountRepository.class);
    private final RefreshTokenRepository tokens = mock(RefreshTokenRepository.class);
    private final RefreshTokenService tokenService = mock(RefreshTokenService.class);
    private final AuthSessionService sessions = mock(AuthSessionService.class);
    private final StaffRefreshTransaction transaction;

    StaffRefreshReuseClassificationTest() {
        DeploymentProperties deployment = new DeploymentProperties();
        deployment.setSite("local");
        transaction = new StaffRefreshTransaction(
                users, tokens, tokenService, new RemoteAccessPolicy(deployment), sessions);
        when(sessions.lockAndEvaluateForRefresh(any(), any(), any()))
                .thenReturn(AuthSessionService.Verdict.ACTIVE);
    }

    @Test
    void bulkRevokedTokenWithAnActiveSessionIsAPlainUnauthorized() {
        RefreshToken token = revokedToken("bulk-revoked", null);

        ApiException denied = assertThrows(ApiException.class, () -> transaction.rotate("bulk-revoked"));

        assertEquals(ErrorCode.UNAUTHORIZED, denied.getCode());
        verifyNoInteractions(tokenService);
        assertEquals(null, token.getReplacedBy());
    }

    @Test
    void rotatedTokenPresentedAgainIsReuse() {
        UUID successor = UUID.randomUUID();
        RefreshToken token = revokedToken("rotated-then-replayed", successor);

        StaffRefreshTransaction.Outcome outcome = transaction.rotate("rotated-then-replayed");

        assertTrue(outcome.reuseDetected());
        assertEquals(token.getId(), outcome.tokenId());
        verifyNoInteractions(tokenService);
    }

    private RefreshToken revokedToken(String raw, UUID replacedBy) {
        UserAccount account = new UserAccount();
        account.setStatus("active");
        RefreshToken token = new RefreshToken();
        token.setUserId(account.getId());
        token.setTokenHash(HashUtil.sha256(raw));
        token.setExpiresAt(OffsetDateTime.now().plusHours(1));
        token.setRevokedAt(OffsetDateTime.now());
        token.setReplacedBy(replacedBy);
        token.setSessionId(UUID.randomUUID());
        when(tokens.findAndLockByTokenHash(HashUtil.sha256(raw))).thenReturn(Optional.of(token));
        when(users.findById(account.getId())).thenReturn(Optional.of(account));
        return token;
    }
}
