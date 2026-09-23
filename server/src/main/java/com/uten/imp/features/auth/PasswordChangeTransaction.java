package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.features.auth.model.PasswordHistory;
import com.uten.imp.features.auth.model.PasswordHistoryRepository;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.TxSessionVars;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.Objects;
import java.util.UUID;

/**
 * 改密的短写事务 (ADR-110): 新密码哈希已在事务外算好。加行锁复核原密码哈希未被并发改动后,
 * 旧哈希入历史、写新哈希、清首登改密与临时密码有效期、bump 授权版本、吊销全部刷新令牌与会话,
 * 再为当前设备开新会话 (保持登录)。
 */
@Service
public class PasswordChangeTransaction {

    private final UserAccountRepository userRepo;
    private final PasswordHistoryRepository passwordHistoryRepo;
    private final RefreshTokenRepository refreshTokenRepo;
    private final AuthSessionService sessions;
    private final TokenIssuer tokenIssuer;
    private final AuditService audit;
    private final TxSessionVars tx;

    public PasswordChangeTransaction(UserAccountRepository userRepo,
                                     PasswordHistoryRepository passwordHistoryRepo,
                                     RefreshTokenRepository refreshTokenRepo,
                                     AuthSessionService sessions,
                                     TokenIssuer tokenIssuer,
                                     AuditService audit,
                                     TxSessionVars tx) {
        this.userRepo = userRepo;
        this.passwordHistoryRepo = passwordHistoryRepo;
        this.refreshTokenRepo = refreshTokenRepo;
        this.sessions = sessions;
        this.tokenIssuer = tokenIssuer;
        this.audit = audit;
        this.tx = tx;
    }

    @Transactional
    public TokenResponse apply(UUID userId, String verifiedOldHash, String newHash) {
        tx.bind();   // 写 users 表(带审计触发器)：首行绑定审计 actor
        UserAccount user = userRepo.findByIdForUpdate(userId)
                .filter(row -> !row.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (!Objects.equals(user.getPasswordHash(), verifiedOldHash)) {
            // 校验原密码之后、落库之前密码已被别处改掉 (另一台设备改密或管理员重置)。
            throw new ApiException(ErrorCode.CONFLICT, "密码刚被修改过，请重新登录后再改");
        }

        // 旧哈希入历史，写新密码
        PasswordHistory history = new PasswordHistory();
        history.setUserId(userId);
        history.setPasswordHash(user.getPasswordHash());
        passwordHistoryRepo.save(history);

        user.setPasswordHash(newHash);
        user.setMustChangePassword(false);
        // 改密成功即脱离临时密码阶段：清除临时密码有效期标记(V297)
        user.setTempPasswordExpiresAt(null);
        user.setLastPasswordChangedAt(OffsetDateTime.now());
        userRepo.save(user);
        if (userRepo.bumpAuthVersion(userId) != 1) {
            throw new ApiException(ErrorCode.UNAUTHORIZED);
        }

        // 撤销所有旧刷新令牌与会话(其他设备被踢)，再为当前设备签发新对
        refreshTokenRepo.revokeAllByUserId(userId);
        sessions.revokeAllForUser(userId, AuthSessionService.REASON_PASSWORD_CHANGED);
        UserAccount refreshedUser = userRepo.findById(userId)
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        audit.logCommitted(
                userId,
                refreshedUser.getLoginAccount(),
                "change_password",
                "users",
                userId.toString(),
                "success");
        return tokenIssuer.issueTokensAfterPasswordChange(refreshedUser);
    }
}
