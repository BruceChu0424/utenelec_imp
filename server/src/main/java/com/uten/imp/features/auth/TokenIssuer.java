package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditRequestContext;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.util.HashUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.features.auth.model.RefreshToken;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.UUID;

/**
 * Issues access/refresh token pairs and provides refresh rotation, logout and profile lookup.
 */
@Service
@Slf4j
public class TokenIssuer {

    private final UserAccountRepository userRepo;
    private final RefreshTokenRepository refreshTokenRepo;
    private final RefreshTokenService refreshTokenService;
    private final StaffRefreshTransaction refreshTransaction;
    private final StaffRefreshCompromiseService compromiseService;
    private final StaffTokenResponseFactory responseFactory;
    private final AuditService audit;

    public TokenIssuer(UserAccountRepository userRepo,
                       RefreshTokenRepository refreshTokenRepo,
                       RefreshTokenService refreshTokenService,
                       StaffRefreshTransaction refreshTransaction,
                       StaffRefreshCompromiseService compromiseService,
                       StaffTokenResponseFactory responseFactory,
                       AuditService audit) {
        this.userRepo = userRepo;
        this.refreshTokenRepo = refreshTokenRepo;
        this.refreshTokenService = refreshTokenService;
        this.refreshTransaction = refreshTransaction;
        this.compromiseService = compromiseService;
        this.responseFactory = responseFactory;
        this.audit = audit;
    }

    /**
     * Rotate in a dedicated transaction. If reuse is detected, family revocation commits in
     * another independent transaction before this facade throws UNAUTHORIZED.
     */
    public TokenResponse refresh(String rawRefresh) {
        StaffRefreshTransaction.Outcome outcome;
        try {
            outcome = refreshTransaction.rotate(rawRefresh);
        } catch (ApiException ex) {
            audit.logExplicit(
                    null,
                    null,
                    "refresh_failed",
                    "refresh_tokens",
                    null,
                    ex.getCode().name().toLowerCase(java.util.Locale.ROOT));
            throw ex;
        }
        if (outcome.reuseDetected()) {
            compromiseService.revoke(
                    outcome.subjectId(), outcome.tokenId(), outcome.sessionId());
            throw new ApiException(ErrorCode.UNAUTHORIZED);
        }
        UserAccount user = outcome.account();
        AuditRequestContext.bindCurrentSessionId(outcome.sessionId());
        return responseFactory.build(
                user, outcome.newRefreshToken(), outcome.sessionId());
    }

    /**
     * Idempotently revoke by refresh-token possession alone. Missing, unknown and
     * already-revoked tokens are deliberately indistinguishable no-ops.
     *
     * <p>A successful revocation records the refresh-token owner as the business actor
     * and the token UUID as the target. The raw token and its hash are never included.
     * Audit runs after commit when a transaction synchronization is available, and all
     * audit/scheduling failures are logged and swallowed so they cannot roll back or
     * alter the security result.
     */
    @Transactional
    public void logout(String rawRefresh) {
        if (rawRefresh == null || rawRefresh.isBlank()) {
            return;
        }
        RefreshToken token = refreshTokenRepo
                .findAndLockByTokenHash(HashUtil.sha256(rawRefresh))
                .filter(row -> row.getRevokedAt() == null)
                .orElse(null);
        if (token == null) {
            return;
        }
        UUID userId = token.getUserId();
        UUID tokenId = token.getId();
        UUID sessionId = token.getSessionId();
        refreshTokenService.revoke(token, null);
        scheduleLogoutAudit(userId, tokenId, sessionId);
    }

    private void scheduleLogoutAudit(
            UUID userId,
            UUID tokenId,
            UUID sessionId) {
        try {
            if (TransactionSynchronizationManager.isSynchronizationActive()
                    && TransactionSynchronizationManager.isActualTransactionActive()) {
                TransactionSynchronizationManager.registerSynchronization(
                        new TransactionSynchronization() {
                            @Override
                            public void afterCommit() {
                                logLogoutBestEffort(userId, tokenId, sessionId);
                            }
                        });
                return;
            }
            logLogoutBestEffort(userId, tokenId, sessionId);
        } catch (RuntimeException ex) {
            // Scheduling/logging is deliberately secondary to token revocation.
            log.error(
                    "Failed to schedule logout audit for userId={} tokenId={}",
                    userId,
                    tokenId,
                    ex);
        }
    }

    private void logLogoutBestEffort(
            UUID userId,
            UUID tokenId,
            UUID sessionId) {
        try {
            audit.logExplicit(
                    userId,
                    null,
                    "logout",
                    "refresh_tokens",
                    tokenId.toString(),
                    "success",
                    sessionId);
        } catch (RuntimeException ex) {
            log.error(
                    "Failed to persist logout audit for userId={} tokenId={}",
                    userId,
                    tokenId,
                    ex);
        }
    }

    @Transactional(readOnly = true)
    public TokenResponse.UserProfile me(java.util.function.Supplier<UUID> userIdSupplier) {
        UUID userId = userIdSupplier.get();
        UserAccount user = userRepo.findById(userId)
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        return responseFactory.profile(user);
    }

    /** Issue a fresh token pair after login or password change. */
    public TokenResponse issueTokens(UserAccount user) {
        RefreshTokenService.IssuedRefreshToken refresh =
                refreshTokenService.issueNewSession(user.getId(), null);
        AuditRequestContext.bindCurrentSessionId(refresh.sessionId());
        return responseFactory.build(
                user, refresh.rawToken(), refresh.sessionId());
    }

    /** Starts the replacement session after a successful password change. */
    public TokenResponse issueTokensAfterPasswordChange(UserAccount user) {
        TokenResponse response = issueTokens(user);
        UUID sessionId = AuditRequestContext.currentSessionId();
        audit.logCommitted(
                user.getId(),
                user.getLoginAccount(),
                "session_start_after_password_change",
                "refresh_tokens",
                sessionId == null ? null : sessionId.toString(),
                "success",
                sessionId);
        return response;
    }
}
