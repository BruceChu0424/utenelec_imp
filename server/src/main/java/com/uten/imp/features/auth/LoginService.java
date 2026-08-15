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
import com.uten.imp.security.TxSessionVars;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.Locale;

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
    private final AuditService audit;
    private final TokenIssuer tokenIssuer;
    private final TxSessionVars tx;
    private final LoginFailureRecorder failureRecorder;
    private final RemoteAccessPolicy remoteAccessPolicy;

    /** 启动时预计算，避免首次未知账号请求多做一次 Argon2 编码而形成可观测时序差。 */
    private final String dummyHash;

    public LoginService(UserAccountRepository userRepo, PasswordEncoder passwordEncoder,
                        LoginRateLimiter rateLimiter,
                        AuditService audit, TokenIssuer tokenIssuer, TxSessionVars tx,
                        LoginFailureRecorder failureRecorder,
                        RemoteAccessPolicy remoteAccessPolicy) {
        this.userRepo = userRepo;
        this.passwordEncoder = passwordEncoder;
        this.rateLimiter = rateLimiter;
        this.audit = audit;
        this.tokenIssuer = tokenIssuer;
        this.tx = tx;
        this.failureRecorder = failureRecorder;
        this.remoteAccessPolicy = remoteAccessPolicy;
        this.dummyHash = passwordEncoder.encode("dummy-password-for-timing");
    }

    /** 登录：顺序为防枚举而设——限流→超长密码 DoS 拦截→账号不存在时跑 dummy Argon2 抹平时序并抛与错密码相同的 BAD_CREDENTIALS→校验密码→密码正确后才暴露停用/锁定/远程访问策略，成功时清失败计数并仅恢复暴力临时锁（不动管理员手动锁/停用）。 */
    @Transactional
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
            passwordEncoder.matches(req.password() == null ? "" : req.password(), dummyHash);
            audit.logExplicit(null, req.loginAccount(), "login_failed",
                    "users", null, "bad_credentials");
            throw new ApiException(ErrorCode.BAD_CREDENTIALS);
        }

        var userOpt = userRepo.findByLoginAccount(req.loginAccount());
        // 账号不存在：跑一次 dummy 校验抹平时序，再抛同样的 BAD_CREDENTIALS（防枚举）
        if (userOpt.isEmpty()) {
            passwordEncoder.matches(req.password(), dummyHash);
            audit.logExplicit(null, req.loginAccount(), "login_failed", "users", null, "account_not_found");
            throw new ApiException(ErrorCode.BAD_CREDENTIALS);
        }

        UserAccount user = userOpt.get();
        tx.bindActor(user.getId(), user.getLoginAccount());

        // 先校验密码（M2：密码正确前不暴露账号状态，防枚举）
        if (!passwordEncoder.matches(req.password(), user.getPasswordHash())) {
            failureRecorder.record(user.getId(), user.getLoginAccount());
            throw new ApiException(ErrorCode.BAD_CREDENTIALS);  // 与账号不存在同消息
        }
        // 密码正确后，才告知停用/锁定（仍锁定期内）
        if ("disabled".equals(user.getStatus())) {
            audit.logExplicit(user.getId(), user.getLoginAccount(), "login_failed",
                    "users", user.getId().toString(), "account_disabled");
            throw new ApiException(ErrorCode.ACCOUNT_DISABLED);
        }
        // 暴力破解临时锁：只看 lockedUntil 时间戳（到期自动恢复，M1）
        if (user.getLockedUntil() != null && user.getLockedUntil().isAfter(OffsetDateTime.now())) {
            audit.logExplicit(user.getId(), user.getLoginAccount(), "login_failed",
                    "users", user.getId().toString(), "account_locked");
            throw new ApiException(ErrorCode.ACCOUNT_LOCKED);
        }
        // 管理员手动锁定（无 lockedUntil）：明确拒绝，文案与暴力临时锁/停用区分
        if ("locked".equals(user.getStatus()) && user.getLockedUntil() == null) {
            audit.logExplicit(user.getId(), user.getLoginAccount(), "login_failed",
                    "users", user.getId().toString(), "account_locked_by_admin");
            throw new ApiException(ErrorCode.ACCOUNT_LOCKED, "账号已被管理员锁定，请联系管理员解锁");
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

        // 成功：清失败计数与暴力临时锁；仅暴力临时锁（lockedUntil 已到期）恢复 status，
        // 不再无条件回写 active（保留管理员手动锁/停用语义）
        user.setFailedAttempts(0);
        user.setLockedUntil(null);
        if ("locked".equals(user.getStatus())) {
            user.setStatus("active");   // 暴力临时锁到期自动恢复
        }
        user.setLastLoginAt(OffsetDateTime.now());
        userRepo.save(user);
        TokenResponse response = tokenIssuer.issueTokens(user);
        audit.logExplicit(user.getId(), user.getLoginAccount(), "login", "users", user.getId().toString(), "success");

        return response;
    }
}
