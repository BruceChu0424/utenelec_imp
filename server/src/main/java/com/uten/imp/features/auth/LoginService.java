package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.SecurityProperties;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.auth.dto.LoginRequest;
import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.LoginRateLimiter;
import com.uten.imp.security.TxSessionVars;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;

/**
 * 登录：防枚举（dummy hash 抹平时序 + 同消息）、失败计数与锁定、限流。
 * 超级管理员能力见 UserAccount.isSuperAdmin / PermissionResolver。
 */
@Service
public class LoginService {

    /** 密码长度上限（防 Argon2 CPU DoS）。 */
    private static final int PASSWORD_MAX_LENGTH = 128;

    private final UserAccountRepository userRepo;
    private final PasswordEncoder passwordEncoder;
    private final LoginRateLimiter rateLimiter;
    private final SecurityProperties securityProps;
    private final SystemSettingsService sysSettings;
    private final AuditService audit;
    private final TokenIssuer tokenIssuer;
    private final TxSessionVars tx;

    private String dummyHash;   // 用于账号不存在时抹平时序（防枚举）

    public LoginService(UserAccountRepository userRepo, PasswordEncoder passwordEncoder,
                        LoginRateLimiter rateLimiter, SecurityProperties securityProps,
                        SystemSettingsService sysSettings,
                        AuditService audit, TokenIssuer tokenIssuer, TxSessionVars tx) {
        this.userRepo = userRepo;
        this.passwordEncoder = passwordEncoder;
        this.rateLimiter = rateLimiter;
        this.securityProps = securityProps;
        this.sysSettings = sysSettings;
        this.audit = audit;
        this.tokenIssuer = tokenIssuer;
        this.tx = tx;
    }

    @Transactional
    public TokenResponse login(LoginRequest req, String ip) {
        rateLimiter.check(ip == null ? "unknown" : ip);

        // 密码长度上限：超长直接拒（防 Argon2 CPU DoS），消息与错密码一致（防枚举）
        if (req.password() == null || req.password().length() > PASSWORD_MAX_LENGTH) {
            ensureDummy();
            if (dummyHash != null) {
                passwordEncoder.matches(req.password(), dummyHash);
            }
            throw new ApiException(ErrorCode.BAD_CREDENTIALS);
        }

        var userOpt = userRepo.findByLoginAccount(req.loginAccount());
        // 账号不存在：跑一次 dummy 校验抹平时序，再抛同样的 BAD_CREDENTIALS（防枚举）
        if (userOpt.isEmpty()) {
            ensureDummy();
            passwordEncoder.matches(req.password(), dummyHash);
            audit.logExplicit(null, req.loginAccount(), "login_failed", "users", null, "account_not_found");
            throw new ApiException(ErrorCode.BAD_CREDENTIALS);
        }

        UserAccount user = userOpt.get();

        // 先校验密码（M2：密码正确前不暴露账号状态，防枚举）
        if (!passwordEncoder.matches(req.password(), user.getPasswordHash())) {
            onBadCredentials(user, ip);
            throw new ApiException(ErrorCode.BAD_CREDENTIALS);  // 与账号不存在同消息
        }
        // 密码正确后，才告知停用/锁定（仍锁定期内）
        if ("disabled".equals(user.getStatus())) {
            throw new ApiException(ErrorCode.ACCOUNT_DISABLED);
        }
        // 暴力破解临时锁：只看 lockedUntil 时间戳（到期自动恢复，M1）
        if (user.getLockedUntil() != null && user.getLockedUntil().isAfter(OffsetDateTime.now())) {
            throw new ApiException(ErrorCode.ACCOUNT_LOCKED);
        }
        // 管理员手动锁定（无 lockedUntil）：明确拒绝，文案与暴力临时锁/停用区分
        if ("locked".equals(user.getStatus()) && user.getLockedUntil() == null) {
            throw new ApiException(ErrorCode.ACCOUNT_LOCKED, "账号已被管理员锁定，请联系管理员解锁");
        }

        // 成功：清失败计数与暴力临时锁；仅暴力临时锁（lockedUntil 已到期）恢复 status，
        // 不再无条件回写 active（保留管理员手动锁/停用语义）
        user.setFailedAttempts(0);
        user.setLockedUntil(null);
        if ("locked".equals(user.getStatus())) {
            user.setStatus("active");   // 暴力临时锁到期自动恢复
        }
        user.setLastLoginAt(OffsetDateTime.now());
        tx.bindActor(user.getId());   // 审计 actor = 登录者本人
        userRepo.save(user);
        audit.logExplicit(user.getId(), user.getLoginAccount(), "login", "users", user.getId().toString(), "success");

        return tokenIssuer.issueTokens(user);
    }

    private void onBadCredentials(UserAccount user, String ip) {
        int attempts = user.getFailedAttempts() + 1;
        user.setFailedAttempts(attempts);
        if (attempts >= sysSettings.readInt("lockout_threshold", 5)) {
            user.setStatus("locked");
            user.setLockedUntil(OffsetDateTime.now().plusMinutes(sysSettings.readInt("lockout_minutes", 15)));
        }
        userRepo.save(user);
        audit.logExplicit(user.getId(), user.getLoginAccount(), "login_failed", "users", user.getId().toString(), "bad_password");
    }

    private void ensureDummy() {
        if (dummyHash == null) {
            dummyHash = passwordEncoder.encode("dummy-password-for-timing");
        }
    }
}
