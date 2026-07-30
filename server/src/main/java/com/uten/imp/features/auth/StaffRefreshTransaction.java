package com.uten.imp.features.auth;

import com.uten.imp.common.util.HashUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.RefreshToken;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * Performs one serialized staff refresh-token rotation.
 *
 * <p>A reuse outcome is returned normally so the row-lock transaction can commit before
 * the caller performs family revocation and throws an authentication exception.
 */
@Service
public class StaffRefreshTransaction {

    private final UserAccountRepository userRepo;
    private final RefreshTokenRepository tokenRepo;
    private final RefreshTokenService tokenService;

    public StaffRefreshTransaction(UserAccountRepository userRepo,
                                   RefreshTokenRepository tokenRepo,
                                   RefreshTokenService tokenService) {
        this.userRepo = userRepo;
        this.tokenRepo = tokenRepo;
        this.tokenService = tokenService;
    }

    public record Outcome(boolean reuseDetected,
                          UUID subjectId,
                          UUID tokenId,
                          UserAccount account,
                          String newRefreshToken) {
        static Outcome reuse(UUID subjectId, UUID tokenId) {
            return new Outcome(true, subjectId, tokenId, null, null);
        }

        static Outcome rotated(UserAccount account, UUID tokenId, String rawToken) {
            return new Outcome(false, account.getId(), tokenId, account, rawToken);
        }
    }

    @Transactional
    public Outcome rotate(String rawRefresh) {
        if (rawRefresh == null || rawRefresh.isBlank()) {
            throw new ApiException(ErrorCode.UNAUTHORIZED);
        }

        RefreshToken token = tokenRepo
                .findAndLockByTokenHash(HashUtil.sha256(rawRefresh))
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));

        if (token.getRevokedAt() != null) {
            return Outcome.reuse(token.getUserId(), token.getId());
        }
        if (!token.isValid()) {
            throw new ApiException(ErrorCode.UNAUTHORIZED);
        }

        UserAccount user = userRepo.findById(token.getUserId())
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if ("disabled".equals(user.getStatus()) || user.isDeleted()) {
            throw new ApiException(ErrorCode.ACCOUNT_DISABLED);
        }
        if (user.getLockedUntil() != null
                && user.getLockedUntil().isAfter(OffsetDateTime.now())) {
            throw new ApiException(ErrorCode.ACCOUNT_LOCKED);
        }
        if ("locked".equals(user.getStatus()) && user.getLockedUntil() == null) {
            throw new ApiException(ErrorCode.ACCOUNT_LOCKED,
                    "账号已被管理员锁定，请联系管理员解锁");
        }

        String newRaw = tokenService.issue(user.getId(), token.getDeviceInfo());
        RefreshToken replacement = tokenRepo
                .findByTokenHash(HashUtil.sha256(newRaw))
                .orElseThrow(() -> new IllegalStateException("issued refresh token not found"));
        tokenService.revoke(token, replacement.getId());
        return Outcome.rotated(user, token.getId(), newRaw);
    }
}
