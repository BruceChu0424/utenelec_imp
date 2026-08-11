package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.util.HashUtil;
import com.uten.imp.features.auth.model.RefreshToken;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccountRepository;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class TokenIssuerLogoutAuditTest {

    @AfterEach
    void clearTransactionSynchronization() {
        if (TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.clearSynchronization();
        }
        TransactionSynchronizationManager.setActualTransactionActive(false);
    }

    @Test
    void matchedTokenAuditsOwnerAndTokenIdOnlyAfterCommit() {
        Fixture fixture = fixture();
        String rawRefresh = "known-refresh-token";
        RefreshToken token = token(rawRefresh);
        when(fixture.tokens.findAndLockByTokenHash(HashUtil.sha256(rawRefresh)))
                .thenReturn(Optional.of(token));
        beginTransactionSynchronization();

        fixture.issuer.logout(rawRefresh);

        verify(fixture.tokenService).revoke(token, null);
        verifyNoInteractions(fixture.audit);
        List<TransactionSynchronization> synchronizations =
                TransactionSynchronizationManager.getSynchronizations();
        assertEquals(1, synchronizations.size());

        synchronizations.getFirst().afterCommit();

        verify(fixture.audit).logExplicit(
                token.getUserId(),
                null,
                "logout",
                "refresh_tokens",
                token.getId().toString(),
                "success");
    }

    @Test
    void unknownTokenIsAnUnauditedNoOp() {
        Fixture fixture = fixture();
        String rawRefresh = "unknown-refresh-token";
        when(fixture.tokens.findAndLockByTokenHash(HashUtil.sha256(rawRefresh)))
                .thenReturn(Optional.empty());
        beginTransactionSynchronization();

        fixture.issuer.logout(rawRefresh);

        assertEquals(0, TransactionSynchronizationManager.getSynchronizations().size());
        verifyNoInteractions(fixture.tokenService, fixture.audit);
    }

    @Test
    void afterCommitAuditFailureCannotChangeCompletedRevocation() {
        Fixture fixture = fixture();
        String rawRefresh = "known-refresh-token-audit-down";
        RefreshToken token = token(rawRefresh);
        when(fixture.tokens.findAndLockByTokenHash(HashUtil.sha256(rawRefresh)))
                .thenReturn(Optional.of(token));
        doThrow(new IllegalStateException("audit unavailable"))
                .when(fixture.audit)
                .logExplicit(
                        token.getUserId(),
                        null,
                        "logout",
                        "refresh_tokens",
                        token.getId().toString(),
                        "success");
        beginTransactionSynchronization();

        fixture.issuer.logout(rawRefresh);
        TransactionSynchronization synchronization =
                TransactionSynchronizationManager.getSynchronizations().getFirst();

        assertDoesNotThrow(synchronization::afterCommit);
        verify(fixture.tokenService).revoke(token, null);
        verify(fixture.audit).logExplicit(
                token.getUserId(),
                null,
                "logout",
                "refresh_tokens",
                token.getId().toString(),
                "success");
    }

    private void beginTransactionSynchronization() {
        TransactionSynchronizationManager.initSynchronization();
        TransactionSynchronizationManager.setActualTransactionActive(true);
    }

    private Fixture fixture() {
        RefreshTokenRepository tokens = mock(RefreshTokenRepository.class);
        RefreshTokenService tokenService = mock(RefreshTokenService.class);
        AuditService audit = mock(AuditService.class);
        TokenIssuer issuer = new TokenIssuer(
                mock(UserAccountRepository.class),
                tokens,
                tokenService,
                mock(StaffRefreshTransaction.class),
                mock(StaffRefreshCompromiseService.class),
                mock(StaffTokenResponseFactory.class),
                audit);
        return new Fixture(issuer, tokens, tokenService, audit);
    }

    private RefreshToken token(String rawRefresh) {
        RefreshToken token = new RefreshToken();
        token.setUserId(UUID.randomUUID());
        token.setTokenHash(HashUtil.sha256(rawRefresh));
        return token;
    }

    private record Fixture(
            TokenIssuer issuer,
            RefreshTokenRepository tokens,
            RefreshTokenService tokenService,
            AuditService audit) {
    }
}
