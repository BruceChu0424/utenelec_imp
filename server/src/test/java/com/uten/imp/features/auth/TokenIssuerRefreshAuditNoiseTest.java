package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class TokenIssuerRefreshAuditNoiseTest {

    @Test
    void successfulAutomaticRotationDoesNotCreateUserActivity() {
        StaffRefreshTransaction refresh = mock(StaffRefreshTransaction.class);
        StaffTokenResponseFactory responses = mock(StaffTokenResponseFactory.class);
        AuditService audit = mock(AuditService.class);
        UserAccount account = mock(UserAccount.class);
        UUID userId = UUID.randomUUID();
        UUID tokenId = UUID.randomUUID();
        when(account.getId()).thenReturn(userId);
        when(refresh.rotate("raw")).thenReturn(new StaffRefreshTransaction.Outcome(
                false, userId, tokenId, account, "replacement"));
        TokenResponse expected = mock(TokenResponse.class);
        when(responses.build(account, "replacement")).thenReturn(expected);
        TokenIssuer issuer = issuer(refresh, responses, audit);

        TokenResponse actual = issuer.refresh("raw");

        assertSame(expected, actual);
        verifyNoInteractions(audit);
    }

    @Test
    void failedRotationStillCreatesSecurityEvidence() {
        StaffRefreshTransaction refresh = mock(StaffRefreshTransaction.class);
        StaffTokenResponseFactory responses = mock(StaffTokenResponseFactory.class);
        AuditService audit = mock(AuditService.class);
        when(refresh.rotate("bad")).thenThrow(new ApiException(ErrorCode.UNAUTHORIZED));
        TokenIssuer issuer = issuer(refresh, responses, audit);

        assertThrows(ApiException.class, () -> issuer.refresh("bad"));

        verify(audit).logExplicit(
                null, null, "refresh_failed", "refresh_tokens", null, "unauthorized");
    }

    private TokenIssuer issuer(
            StaffRefreshTransaction refresh,
            StaffTokenResponseFactory responses,
            AuditService audit) {
        return new TokenIssuer(
                mock(UserAccountRepository.class),
                mock(RefreshTokenRepository.class),
                mock(RefreshTokenService.class),
                refresh,
                mock(StaffRefreshCompromiseService.class),
                responses,
                audit);
    }
}
