package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.TxSessionVars;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.Objects;
import java.util.UUID;

/**
 * 登录成功的短写事务 (ADR-110): 密码已在事务外校验通过, 这里只加行锁复核「校验时看到的
 * 密码哈希与账号状态仍然成立」, 然后清失败计数、开服务端会话、签发令牌并记登录审计。
 * 校验与写入之间密码被改、账号被停用或锁定, 一律按错密码处理。
 */
@Service
public class StaffLoginTransaction {

    private final UserAccountRepository userRepo;
    private final TokenIssuer tokenIssuer;
    private final AuditService audit;
    private final TxSessionVars tx;

    public StaffLoginTransaction(UserAccountRepository userRepo, TokenIssuer tokenIssuer,
                                 AuditService audit, TxSessionVars tx) {
        this.userRepo = userRepo;
        this.tokenIssuer = tokenIssuer;
        this.audit = audit;
        this.tx = tx;
    }

    @Transactional
    public TokenResponse complete(UUID userId, String verifiedPasswordHash) {
        UserAccount user = userRepo.findByIdForUpdate(userId)
                .filter(row -> !row.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.BAD_CREDENTIALS));
        tx.bindActor(user.getId(), user.getLoginAccount());
        boolean temporarilyLocked = user.getLockedUntil() != null
                && user.getLockedUntil().isAfter(OffsetDateTime.now());
        boolean manuallyLocked = "locked".equals(user.getStatus()) && user.getLockedUntil() == null;
        if (!Objects.equals(user.getPasswordHash(), verifiedPasswordHash)
                || "disabled".equals(user.getStatus())
                || temporarilyLocked
                || manuallyLocked) {
            throw new ApiException(ErrorCode.BAD_CREDENTIALS);
        }
        // 成功：清失败计数与暴力临时锁；仅暴力临时锁(lockedUntil 已到期)恢复 status，
        // 不再无条件回写 active(保留管理员手动锁/停用语义)
        user.setFailedAttempts(0);
        user.setLockedUntil(null);
        if ("locked".equals(user.getStatus())) {
            user.setStatus("active");   // 暴力临时锁到期自动恢复
        }
        user.setLastLoginAt(OffsetDateTime.now());
        userRepo.save(user);
        TokenResponse response = tokenIssuer.issueTokens(user);
        audit.logCommitted(user.getId(), user.getLoginAccount(),
                "login", "users", user.getId().toString(), "success");
        return response;
    }
}
