package com.uten.imp.features.auth;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.auth.dto.ChangePasswordRequest;
import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.features.auth.model.PasswordHistory;
import com.uten.imp.features.auth.model.PasswordHistoryRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.PasswordPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;

import java.util.List;

/**
 * 改密 (首登强制 / 设置中), 三段式 (ADR-110; security-03/04):
 * ① 短读事务取账号与历史哈希 → ② 事务外: 原密码经 {@link StepUpService} 校验 (与再认证共享失败计数),
 * 强度与历史比对, 新密码哈希 (都经哈希并发闸门) → ③ 短写事务 {@link PasswordChangeTransaction}
 * 加行锁复核后落库、吊销全部旧会话并为当前设备开新会话。
 */
@Service
public class PasswordService {

    /** 密码长度上限（防 Argon2 CPU DoS）。 */
    private static final int PASSWORD_MAX_LENGTH = 128;

    private final UserAccountRepository userRepo;
    private final PasswordHistoryRepository passwordHistoryRepo;
    private final PasswordEncoder passwordEncoder;
    private final PasswordPolicy passwordPolicy;
    private final SystemSettingsService sysSettings;
    private final SecurityContextCurrentUser currentUser;
    private final StepUpService stepUp;
    private final PasswordChangeTransaction changeTransaction;

    public PasswordService(UserAccountRepository userRepo, PasswordHistoryRepository passwordHistoryRepo,
                           PasswordEncoder passwordEncoder, PasswordPolicy passwordPolicy,
                           SystemSettingsService sysSettings, SecurityContextCurrentUser currentUser,
                           StepUpService stepUp, PasswordChangeTransaction changeTransaction) {
        this.userRepo = userRepo;
        this.passwordHistoryRepo = passwordHistoryRepo;
        this.passwordEncoder = passwordEncoder;
        this.passwordPolicy = passwordPolicy;
        this.sysSettings = sysSettings;
        this.currentUser = currentUser;
        this.stepUp = stepUp;
        this.changeTransaction = changeTransaction;
    }

    public TokenResponse changePassword(ChangePasswordRequest req) {
        // 长度上限（防 Argon2 CPU DoS）
        if (req.oldPassword() == null || req.oldPassword().length() > PASSWORD_MAX_LENGTH
                || req.newPassword() == null || req.newPassword().length() > PASSWORD_MAX_LENGTH) {
            throw new ApiException(ErrorCode.REAUTH_FAILED, "原密码不正确");
        }
        AuthUser principal = currentUser.get()
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        // ① 短读 (仓库方法自带只读事务)
        UserAccount user = userRepo.findById(principal.getId())
                .filter(row -> !row.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));

        // ② 原密码: 与再认证共享失败计数, 连错达上限暂停并踢掉当前会话
        stepUp.verifyPassword(user.getId(), user.getLoginAccount(), req.oldPassword(),
                principal.getSessionId(), StepUpService.Purpose.CHANGE_PASSWORD);

        passwordPolicy.validate(req.newPassword(), user.getLoginAccount());
        // The old password was verified above. Reject the same value even when
        // historical lookback is disabled, without another expensive hash check.
        if (req.newPassword().equals(req.oldPassword())) {
            throw new ApiException(ErrorCode.PASSWORD_REUSE);
        }
        // 防重用：最近 N 条历史
        List<PasswordHistory> recent = passwordHistoryRepo.findRecent(
                user.getId(), sysSettings.readInt(SystemSettingKey.PASSWORD_HISTORY_SIZE));
        for (PasswordHistory h : recent) {
            if (passwordEncoder.matches(req.newPassword(), h.getPasswordHash())) {
                throw new ApiException(ErrorCode.PASSWORD_REUSE);
            }
        }
        String newHash = passwordEncoder.encode(req.newPassword());

        // ③ 短写事务
        return changeTransaction.apply(user.getId(), user.getPasswordHash(), newHash);
    }
}
