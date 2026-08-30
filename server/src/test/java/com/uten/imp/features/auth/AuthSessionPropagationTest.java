package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditRequestContext;
import com.uten.imp.audit.AuditService;
import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.features.auth.model.RefreshToken;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.RemoteAccessPolicy;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import java.time.OffsetDateTime;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class AuthSessionPropagationTest {

    @AfterEach
    void resetRequestContext() {
        RequestContextHolder.resetRequestAttributes();
    }

    @Test
    void initialLoginTokenBindsSessionToTheRealMockRequest() {
        UUID userId = UUID.randomUUID();
        UUID sessionId = UUID.randomUUID();
        UUID tokenId = UUID.randomUUID();
        UserAccount user = mock(UserAccount.class);
        when(user.getId()).thenReturn(userId);
        RefreshTokenService refreshTokens = mock(RefreshTokenService.class);
        when(refreshTokens.issueNewSession(userId, null)).thenReturn(
                new RefreshTokenService.IssuedRefreshToken(
                        "raw-refresh", tokenId, sessionId,
                        OffsetDateTime.now().plusDays(7)));
        StaffTokenResponseFactory responses = mock(StaffTokenResponseFactory.class);
        TokenResponse expected = mock(TokenResponse.class);
        when(responses.build(user, "raw-refresh", sessionId)).thenReturn(expected);
        MockHttpServletRequest request = new MockHttpServletRequest();
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(request));
        TokenIssuer issuer = issuer(refreshTokens, responses, mock(AuditService.class));

        TokenResponse actual = issuer.issueTokens(user);

        assertSame(expected, actual);
        assertEquals(sessionId,
                request.getAttribute(AuditRequestContext.SESSION_ID_ATTRIBUTE));
        verify(responses).build(user, "raw-refresh", sessionId);
    }

    @Test
    void passwordChangeStartsAnAuditedReplacementSession() {
        UUID userId = UUID.randomUUID();
        UUID sessionId = UUID.randomUUID();
        UserAccount user = mock(UserAccount.class);
        when(user.getId()).thenReturn(userId);
        when(user.getLoginAccount()).thenReturn("E1001");
        RefreshTokenService refreshTokens = mock(RefreshTokenService.class);
        when(refreshTokens.issueNewSession(userId, null)).thenReturn(
                new RefreshTokenService.IssuedRefreshToken(
                        "replacement", UUID.randomUUID(), sessionId,
                        OffsetDateTime.now().plusDays(7)));
        StaffTokenResponseFactory responses = mock(StaffTokenResponseFactory.class);
        TokenResponse expected = mock(TokenResponse.class);
        when(responses.build(user, "replacement", sessionId)).thenReturn(expected);
        AuditService audit = mock(AuditService.class);
        RequestContextHolder.setRequestAttributes(
                new ServletRequestAttributes(new MockHttpServletRequest()));
        TokenIssuer issuer = issuer(refreshTokens, responses, audit);

        assertSame(expected, issuer.issueTokensAfterPasswordChange(user));

        verify(audit).logCommitted(
                userId,
                "E1001",
                "session_start_after_password_change",
                "refresh_tokens",
                sessionId.toString(),
                "success",
                sessionId);
    }

    @Test
    void staffRefreshRotationKeepsTheExistingSessionId() {
        String raw = "existing-refresh";
        UUID sessionId = UUID.randomUUID();
        RefreshToken current = new RefreshToken();
        current.setUserId(UUID.randomUUID());
        current.setSessionId(sessionId);
        current.setTokenHash(com.uten.imp.common.util.HashUtil.sha256(raw));
        current.setExpiresAt(OffsetDateTime.now().plusHours(1));
        UserAccount user = new UserAccount();
        user.setStatus("active");
        RefreshTokenRepository repository = mock(RefreshTokenRepository.class);
        when(repository.findAndLockByTokenHash(current.getTokenHash()))
                .thenReturn(Optional.of(current));
        UserAccountRepository users = mock(UserAccountRepository.class);
        when(users.findById(current.getUserId())).thenReturn(Optional.of(user));
        RefreshTokenService tokenService = mock(RefreshTokenService.class);
        UUID replacementId = UUID.randomUUID();
        when(tokenService.issueInSession(
                user.getId(), current.getDeviceInfo(), sessionId)).thenReturn(
                new RefreshTokenService.IssuedRefreshToken(
                        "replacement", replacementId, sessionId,
                        OffsetDateTime.now().plusDays(7)));
        StaffRefreshTransaction transaction = new StaffRefreshTransaction(
                users, repository, tokenService, mock(RemoteAccessPolicy.class));

        StaffRefreshTransaction.Outcome outcome = transaction.rotate(raw);

        assertEquals(sessionId, outcome.sessionId());
        assertEquals("replacement", outcome.newRefreshToken());
        verify(tokenService).revoke(current, replacementId);
    }

    private TokenIssuer issuer(
            RefreshTokenService refreshTokens,
            StaffTokenResponseFactory responses,
            AuditService audit) {
        return new TokenIssuer(
                mock(UserAccountRepository.class),
                mock(RefreshTokenRepository.class),
                refreshTokens,
                mock(StaffRefreshTransaction.class),
                mock(StaffRefreshCompromiseService.class),
                responses,
                audit);
    }
}
