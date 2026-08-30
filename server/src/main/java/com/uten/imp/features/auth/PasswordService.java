package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.SecurityProperties;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.auth.dto.ChangePasswordRequest;
import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.features.auth.model.PasswordHistory;
import com.uten.imp.features.auth.model.PasswordHistoryRepository;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.PasswordPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 密码管理：改密（强度 + 历史防重用 + 撤销旧令牌）与二次确认密码。
 */
@Service
public class PasswordService {

    /** 密码长度上限（防 Argon2 CPU DoS）。 */
    private static final int PASSWORD_MAX_LENGTH = 128;

    private final UserAccountRepository userRepo;
    private final PasswordHistoryRepository passwordHistoryRepo;
    private final RefreshTokenRepository refreshTokenRepo;
    private final PasswordEncoder passwordEncoder;
    private final PasswordPolicy passwordPolicy;
    private final SecurityProperties securityProps;
    private final SystemSettingsService sysSettings;
    private final SecurityContextCurrentUser currentUser;
    private final AuditService audit;
    private final TokenIssuer tokenIssuer;
    private final TxSessionVars tx;

    public PasswordService(UserAccountRepository userRepo, PasswordHistoryRepository passwordHistoryRepo,
                           RefreshTokenRepository refreshTokenRepo, PasswordEncoder passwordEncoder,
                           PasswordPolicy passwordPolicy, SecurityProperties securityProps,
                           SystemSettingsService sysSettings,
                           SecurityContextCurrentUser currentUser, AuditService audit, TokenIssuer tokenIssuer,
                           TxSessionVars tx) {
        this.userRepo = userRepo;
        this.passwordHistoryRepo = passwordHistoryRepo;
        this.refreshTokenRepo = refreshTokenRepo;
        this.passwordEncoder = passwordEncoder;
        this.passwordPolicy = passwordPolicy;
        this.securityProps = securityProps;
        this.sysSettings = sysSettings;
        this.currentUser = currentUser;
        this.audit = audit;
        this.tokenIssuer = tokenIssuer;
        this.tx = tx;
    }

    /**
     * 改密（首登强制 / 设置中）：校验旧密码 → 强度 → 历史 → Argon2id 入库 → 清 mustChangePassword →
     * 撤销所有旧刷新令牌（其他设备被踢）→ 为当前设备签发新令牌对（保持登录）。返回新令牌。
     */
    @Transactional
    public TokenResponse changePassword(ChangePasswordRequest req) {
        tx.bind();   // 写 users 表（带审计触发器）：首行绑定审计 actor
        // 长度上限（防 Argon2 CPU DoS）
        if (req.oldPassword() == null || req.oldPassword().length() > PASSWORD_MAX_LENGTH
                || req.newPassword() == null || req.newPassword().length() > PASSWORD_MAX_LENGTH) {
            throw new ApiException(ErrorCode.BAD_CREDENTIALS);
        }

        UUID userId = currentUser.requireId();
        UserAccount user = userRepo.findById(userId)
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));

        if (!passwordEncoder.matches(req.oldPassword(), user.getPasswordHash())) {
            audit.logExplicit(userId, user.getLoginAccount(), "change_password_failed", "users", userId.toString(), "bad_old_password");
            throw new ApiException(ErrorCode.BAD_CREDENTIALS, "原密码不正确");
        }

        passwordPolicy.validate(req.newPassword(), user.getLoginAccount());

        // 防重用：最近 N 条历史
        for (PasswordHistory h : passwordHistoryRepo.findRecent(userId, sysSettings.readInt("password_history_size", 5))) {
            if (passwordEncoder.matches(req.newPassword(), h.getPasswordHash())) {
                throw new ApiException(ErrorCode.PASSWORD_REUSE);
            }
        }

        // 旧哈希入历史，写新密码
        PasswordHistory history = new PasswordHistory();
        history.setUserId(userId);
        history.setPasswordHash(user.getPasswordHash());
        passwordHistoryRepo.save(history);

        user.setPasswordHash(passwordEncoder.encode(req.newPassword()));
        user.setMustChangePassword(false);
        // 改密成功即脱离临时密码阶段：清除临时密码有效期标记（V297）
        user.setTempPasswordExpiresAt(null);
        user.setLastPasswordChangedAt(OffsetDateTime.now());
        userRepo.save(user);
        if (userRepo.bumpAuthVersion(userId) != 1) {
            throw new ApiException(ErrorCode.UNAUTHORIZED);
        }

        // 撤销所有旧刷新令牌（其他设备失效），再为当前设备签发新对
        refreshTokenRepo.revokeAllByUserId(userId);
        UserAccount refreshedUser = userRepo.findById(userId)
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        audit.logCommitted(
                userId,
                refreshedUser.getLoginAccount(),
                "change_password",
                "users",
                userId.toString(),
                "success");
        return tokenIssuer.issueTokens(refreshedUser);
    }

    /**
     * 二次确认密码（不改密；用于"修改个人信息/手机/姓名"等敏感动作前的校验）。
     * 不计入登录失败计数（与登录错密码隔离，避免被攻击者借道锁定账号）。
     */
    @Transactional(readOnly = true)
    public void verifyPassword(String password) {
        if (password == null || password.isEmpty()) {
            throw new ApiException(ErrorCode.BAD_CREDENTIALS);
        }
        UUID userId = currentUser.requireId();
        UserAccount user = userRepo.findById(userId)
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (!passwordEncoder.matches(password, user.getPasswordHash())) {
            audit.logExplicit(userId, user.getLoginAccount(),
                    "verify_password_failed", "users", userId.toString(), "bad_password");
            throw new ApiException(ErrorCode.BAD_CREDENTIALS, "密码错误");
        }
        audit.logExplicit(userId, user.getLoginAccount(),
                "verify_password", "users", userId.toString(), "success");
    }
}
