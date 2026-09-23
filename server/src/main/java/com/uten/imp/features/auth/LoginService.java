package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.dto.LoginRequest;
import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.LoginRateLimiter;
import com.uten.imp.security.RemoteAccessPolicy;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;

import java.time.OffsetDateTime;
import java.util.Locale;

/**
 * 登录编排 (ADR-110; security-01/03)。
 *
 * <p>三段式, 密码哈希不占数据库连接: ① 短读事务取账号快照 → ② 事务外校验密码 (经哈希并发闸门)
 * → ③ 短写事务 {@link StaffLoginTransaction} 加行锁复核并签发会话。失败计数由
 * {@link LoginFailureRecorder} 在独立短事务里落库。</p>
 *
 * <p>防枚举与锁定: 账号不存在、密码错误、暴力临时锁定期间 (不论密码对错) 三种情况返回完全相同的
 * BAD_CREDENTIALS 码与文案, 且都只做一次 Argon2 (锁定期只跑 dummy 哈希, 不校验真实密码)。
 * 锁定期内的每次尝试继续计数并顺延锁定。停用、管理员锁定、临时密码过期、未授权外网访问只在
 * 锁定期外且密码正确时才告知。</p>
 */
@Service
public class LoginService {

    /** 密码长度上限（防 Argon2 CPU DoS）。 */
    private static final int PASSWORD_MAX_LENGTH = 128;

    private final UserAccountRepository userRepo;
    private final PasswordEncoder passwordEncoder;
    private final LoginRateLimiter rateLimiter;
    private final AuditService audit;
    private final LoginFailureRecorder failureRecorder;
    private final RemoteAccessPolicy remoteAccessPolicy;
    private final StaffLoginTransaction loginTransaction;

    /** 启动时预计算，避免首次未知账号请求多做一次 Argon2 编码而形成可观测时序差。 */
    private final String dummyHash;

    public LoginService(UserAccountRepository userRepo, PasswordEncoder passwordEncoder,
                        LoginRateLimiter rateLimiter,
                        AuditService audit,
                        LoginFailureRecorder failureRecorder,
                        RemoteAccessPolicy remoteAccessPolicy,
                        StaffLoginTransaction loginTransaction) {
        this.userRepo = userRepo;
        this.passwordEncoder = passwordEncoder;
        this.rateLimiter = rateLimiter;
        this.audit = audit;
        this.failureRecorder = failureRecorder;
        this.remoteAccessPolicy = remoteAccessPolicy;
        this.loginTransaction = loginTransaction;
        this.dummyHash = passwordEncoder.encode("dummy-password-for-timing");
    }

    public TokenResponse login(LoginRequest req, String ip) {
        try {
            rateLimiter.check(
                    LoginRateLimiter.Scope.STAFF_LOGIN,
                    ip,
                    req.loginAccount());
        } catch (ApiException ex) {
            audit.logExplicit(null, req.loginAccount(), "login_failed",
                    "users", null, ex.getCode().name().toLowerCase(Locale.ROOT));
            throw ex;
        }

        // 密码长度上限：超长直接拒（防 Argon2 CPU DoS），消息与错密码一致（防枚举）
        if (req.password() == null || req.password().length() > PASSWORD_MAX_LENGTH) {
            passwordEncoder.matches(req.password() == null ? "" : truncate(req.password()), dummyHash);
            audit.logExplicit(null, req.loginAccount(), "login_failed",
                    "users", null, "bad_credentials");
            throw new ApiException(ErrorCode.BAD_CREDENTIALS);
        }

        // ① 短读事务 (仓库方法自带只读事务, 返回脱管快照)
        UserAccount user = userRepo.findByLoginAccount(req.loginAccount()).orElse(null);
        if (user == null) {
            // 账号不存在：跑一次 dummy 校验抹平时序，再抛同样的 BAD_CREDENTIALS（防枚举）
            passwordEncoder.matches(req.password(), dummyHash);
            audit.logExplicit(null, req.loginAccount(), "login_failed", "users", null, "account_not_found");
            throw new ApiException(ErrorCode.BAD_CREDENTIALS);
        }

        // 暴力破解临时锁定期: 不校验真实密码 (否则锁定只拦成功登录, 仍在给出对错信号),
        // 只跑 dummy 哈希抹平时序, 继续计数并顺延锁定, 返回与错密码完全相同的结果。
        if (user.getLockedUntil() != null && user.getLockedUntil().isAfter(OffsetDateTime.now())) {
            passwordEncoder.matches(req.password(), dummyHash);
            failureRecorder.record(user.getId(), user.getLoginAccount(), "attempt_while_locked");
            throw new ApiException(ErrorCode.BAD_CREDENTIALS);
        }

        // ② 事务外校验密码
        if (!passwordEncoder.matches(req.password(), user.getPasswordHash())) {
            failureRecorder.record(user.getId(), user.getLoginAccount(), "bad_password");
            throw new ApiException(ErrorCode.BAD_CREDENTIALS);  // 与账号不存在同消息
        }
        // 密码正确后，才告知停用/管理员锁定/临时密码过期/外网授权
        rejectUnusableAccount(user);

        // ③ 短写事务: 行锁复核 + 清失败计数 + 开会话签发令牌 + 登录审计
        return loginTransaction.complete(user.getId(), user.getPasswordHash());
    }

    private void rejectUnusableAccount(UserAccount user) {
        if ("disabled".equals(user.getStatus())) {
            audit.logExplicit(user.getId(), user.getLoginAccount(), "login_failed",
                    "users", user.getId().toString(), "account_disabled");
            throw new ApiException(ErrorCode.ACCOUNT_DISABLED);
        }
        // 管理员手动锁定（无 lockedUntil）：明确拒绝，文案与暴力临时锁/停用区分
        if ("locked".equals(user.getStatus()) && user.getLockedUntil() == null) {
            audit.logExplicit(user.getId(), user.getLoginAccount(), "login_failed",
                    "users", user.getId().toString(), "account_locked_by_admin");
            throw new ApiException(ErrorCode.ACCOUNT_LOCKED, "账号已被管理员锁定，请联系管理员解锁");
        }
        // 临时密码有效期: 开通账号与重置密码都写 tempPasswordExpiresAt; 过期后临时密码不再可用,
        // 提示员工重新找管理员设置（密码已校验正确才提示，不助枚举）。
        if (user.isMustChangePassword() && user.getTempPasswordExpiresAt() != null
                && !user.getTempPasswordExpiresAt().isAfter(OffsetDateTime.now())) {
            audit.logExplicit(user.getId(), user.getLoginAccount(), "login_failed",
                    "users", user.getId().toString(), "temporary_password_expired");
            throw new ApiException(ErrorCode.UNAUTHORIZED,
                    "临时密码已过期，请联系管理员重新设置临时密码");
        }
        // Do not reveal remote authorization until password and account status are
        // valid. Still enforce it before successful-login state or token issuance.
        try {
            remoteAccessPolicy.requireStaffAccess(user);
        } catch (ApiException denied) {
            audit.logExplicit(user.getId(), user.getLoginAccount(), "login_failed",
                    "users", user.getId().toString(), "remote_access_denied");
            throw denied;
        }
    }

    private static String truncate(String value) {
        return value.length() > PASSWORD_MAX_LENGTH ? value.substring(0, PASSWORD_MAX_LENGTH) : value;
    }
}
