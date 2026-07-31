package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.util.HashUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

/**
 * Issues access/refresh token pairs and provides refresh rotation, logout and profile lookup.
 */
@Service
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
            audit.logExplicit(null, null, "refresh_failed", "refresh_tokens",
                    null, ex.getCode().name().toLowerCase(java.util.Locale.ROOT));
            throw ex;
        }
        if (outcome.reuseDetected()) {
            compromiseService.revoke(outcome.subjectId(), outcome.tokenId());
            throw new ApiException(ErrorCode.UNAUTHORIZED);
        }
        UserAccount user = outcome.account();
        audit.logExplicit(user.getId(), user.getLoginAccount(), "refresh_token",
                "refresh_tokens", outcome.tokenId().toString(), "success");
        return responseFactory.build(user, outcome.newRefreshToken());
    }

    @Transactional
    public void logout(String rawRefresh) {
        if (rawRefresh == null || rawRefresh.isBlank()) {
            return;
        }
        refreshTokenRepo.findByTokenHash(HashUtil.sha256(rawRefresh))
                .ifPresent(token -> refreshTokenService.revoke(token, null));
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
        String refresh = refreshTokenService.issue(user.getId(), null);
        return responseFactory.build(user, refresh);
    }
}
