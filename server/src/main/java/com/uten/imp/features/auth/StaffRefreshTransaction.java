package com.uten.imp.features.auth;

import com.uten.imp.common.util.HashUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.RefreshToken;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.RemoteAccessPolicy;
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
    private final RemoteAccessPolicy remoteAccessPolicy;
    private final AuthSessionService sessions;

    public StaffRefreshTransaction(UserAccountRepository userRepo,
                                   RefreshTokenRepository tokenRepo,
                                   RefreshTokenService tokenService,
                                   RemoteAccessPolicy remoteAccessPolicy,
                                   AuthSessionService sessions) {
        this.userRepo = userRepo;
        this.tokenRepo = tokenRepo;
        this.tokenService = tokenService;
        this.remoteAccessPolicy = remoteAccessPolicy;
        this.sessions = sessions;
    }

    public record Outcome(boolean reuseDetected,
                          UUID subjectId,
                          UUID tokenId,
                          UUID sessionId,
                          UserAccount account,
                          String newRefreshToken) {
        static Outcome reuse(UUID subjectId, UUID tokenId, UUID sessionId) {
            return new Outcome(true, subjectId, tokenId, sessionId, null, null);
        }

        static Outcome rotated(
                UserAccount account,
                UUID tokenId,
                UUID sessionId,
                String rawToken) {
            return new Outcome(
                    false, account.getId(), tokenId, sessionId, account, rawToken);
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

        // 服务端会话是刷新的前提 (ADR-110): 已吊销 (登出/改密/停用/空闲超时…)、超过从登录起算的
        // 绝对期限、或空闲超时的会话一律不能再换新令牌。锁住会话行, 与并发登出串行。
        AuthSessionService.Verdict session = sessions.lockAndEvaluateForRefresh(
                token.getSessionId(), token.getUserId(), null);
        if (token.getRevokedAt() != null) {
            // A remote-access toggle revokes the whole family. On the cloud site,
            // preserve the explicit policy response instead of misclassifying that
            // intentional revocation as a stolen-token reuse incident.
            UserAccount revokedUser = userRepo.findById(token.getUserId())
                    .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
            remoteAccessPolicy.requireStaffAccess(revokedUser);
            if (token.getReplacedBy() == null || session != AuthSessionService.Verdict.ACTIVE) {
                // 只有「已被轮换出新令牌」的旧令牌再次出现才是被盗重放。整族被作废 (改登录手机号、
                // 权限变更、远程访问变动…) 或会话本身已结束 (登出/改密/停用/空闲超时…) 时,
                // 旧令牌只是作废凭证: 普通 401 让客户端回登录页, 不误报安全事件、不连坐其它会话。
                throw new ApiException(ErrorCode.UNAUTHORIZED);
            }
            return Outcome.reuse(
                    token.getUserId(), token.getId(), token.getSessionId());
        }
        if (!token.isValid() || session != AuthSessionService.Verdict.ACTIVE) {
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

        // Reject before issuing a replacement or mutating the current token family.
        remoteAccessPolicy.requireStaffAccess(user);

        RefreshTokenService.IssuedRefreshToken replacement =
                tokenService.issueInSession(
                        user.getId(), token.getDeviceInfo(), token.getSessionId(),
                        token.getExpiresAt());
        tokenService.revoke(token, replacement.tokenId());
        return Outcome.rotated(
                user,
                token.getId(),
                token.getSessionId(),
                replacement.rawToken());
    }
}
