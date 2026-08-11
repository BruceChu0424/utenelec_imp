package com.uten.imp.features.visitor;

import com.uten.imp.common.util.HashUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

/**
 * Performs one serialized visitor refresh-token rotation.
 */
@Service
public class VisitorRefreshTransaction {

    private final VisitorRefreshTokenRepository tokenRepo;
    private final VisitorRefreshTokenService tokenService;
    private final VisitorAccountRepository accountRepo;

    public VisitorRefreshTransaction(VisitorRefreshTokenRepository tokenRepo,
                                     VisitorRefreshTokenService tokenService,
                                     VisitorAccountRepository accountRepo) {
        this.tokenRepo = tokenRepo;
        this.tokenService = tokenService;
        this.accountRepo = accountRepo;
    }

    public record Outcome(boolean reuseDetected,
                          UUID subjectId,
                          UUID tokenId,
                          VisitorAccount account,
                          String newRefreshToken) {
        static Outcome reuse(UUID subjectId, UUID tokenId) {
            return new Outcome(true, subjectId, tokenId, null, null);
        }

        static Outcome rotated(VisitorAccount account, UUID tokenId, String rawToken) {
            return new Outcome(false, account.getId(), tokenId, account, rawToken);
        }
    }

    @Transactional
    public Outcome rotate(String rawRefresh, String deviceInfo) {
        if (rawRefresh == null || rawRefresh.isBlank()) {
            throw new ApiException(ErrorCode.UNAUTHORIZED);
        }

        VisitorRefreshToken token = tokenRepo
                .findAndLockByTokenHash(HashUtil.sha256(rawRefresh))
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (token.getRevokedAt() != null) {
            return Outcome.reuse(token.getVisitorAccountId(), token.getId());
        }
        if (!token.isValid()) {
            throw new ApiException(ErrorCode.UNAUTHORIZED);
        }

        VisitorAccount account = accountRepo.findById(token.getVisitorAccountId())
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if ("blocked".equals(account.getStatus())) {
            throw new ApiException(ErrorCode.VISITOR_BLOCKED);
        }

        String newRaw = tokenService.issue(account.getId(), deviceInfo);
        tokenService.revoke(token, null);
        return Outcome.rotated(account, token.getId(), newRaw);
    }
}
