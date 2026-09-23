package com.uten.imp.features.visitor;

import com.uten.imp.common.util.HashUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.AuthSessionService;
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
    private final AuthSessionService sessions;

    public VisitorRefreshTransaction(VisitorRefreshTokenRepository tokenRepo,
                                     VisitorRefreshTokenService tokenService,
                                     VisitorAccountRepository accountRepo,
                                     AuthSessionService sessions) {
        this.tokenRepo = tokenRepo;
        this.tokenService = tokenService;
        this.accountRepo = accountRepo;
        this.sessions = sessions;
    }

    public record Outcome(boolean reuseDetected,
                          UUID subjectId,
                          UUID tokenId,
                          UUID sessionId,
                          VisitorAccount account,
                          String newRefreshToken) {
        static Outcome reuse(UUID subjectId, UUID tokenId, UUID sessionId) {
            return new Outcome(true, subjectId, tokenId, sessionId, null, null);
        }

        static Outcome rotated(
                VisitorAccount account,
                UUID tokenId,
                UUID sessionId,
                String rawToken) {
            return new Outcome(
                    false, account.getId(), tokenId, sessionId, account, rawToken);
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
        // 与员工同口径: 会话已吊销/超绝对期限/空闲超时一律不能再换新令牌 (ADR-110)。
        AuthSessionService.Verdict session = sessions.lockAndEvaluateForRefresh(
                token.getSessionId(), null, token.getVisitorAccountId());
        if (token.getRevokedAt() != null) {
            // 与员工同口径: 只有已被轮换出新令牌的旧令牌再次出现才算重放。
            if (token.getReplacedBy() == null || session != AuthSessionService.Verdict.ACTIVE) {
                throw new ApiException(ErrorCode.UNAUTHORIZED);
            }
            return Outcome.reuse(
                    token.getVisitorAccountId(), token.getId(), token.getSessionId());
        }
        if (!token.isValid() || session != AuthSessionService.Verdict.ACTIVE) {
            throw new ApiException(ErrorCode.UNAUTHORIZED);
        }

        VisitorAccount account = accountRepo.findById(token.getVisitorAccountId())
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if ("blocked".equals(account.getStatus())) {
            throw new ApiException(ErrorCode.VISITOR_BLOCKED);
        }

        VisitorRefreshTokenService.IssuedRefreshToken replacement =
                tokenService.issueInSession(
                        account.getId(), deviceInfo, token.getSessionId(),
                        token.getExpiresAt());
        tokenService.revoke(token, replacement.tokenId());
        return Outcome.rotated(
                account,
                token.getId(),
                token.getSessionId(),
                replacement.rawToken());
    }
}
