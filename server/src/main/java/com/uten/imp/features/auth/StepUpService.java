package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.util.HashUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.StepUpInterceptor;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import java.security.SecureRandom;
import java.time.Duration;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.Base64;
import java.util.List;
import java.util.UUID;

/**
 * 统一的敏感操作再认证 (ADR-110; security-04/05)。
 *
 * <p>所有「当前登录的人再输一次自己的密码」都走这里并共享一份失败计数: 换取再认证凭证
 * ({@code POST /api/auth/step-up})、改密时的原密码、进入切换人。连续输错达到「账号锁定阈值」
 * 即暂停验证「锁定时长」分钟, 并吊销当前会话 (被盗的会话不能继续高速试密码)。</p>
 *
 * <p>凭证是 256 位随机串, 只存哈希在本会话行上, 5 分钟有效, 核销一次即清空; 必须由签发它的
 * 同一个人、同一个会话使用。模拟身份期间不能换取凭证。密码校验在事务外执行, 经过哈希并发闸门。</p>
 */
@Service
public class StepUpService {

    public static final Duration TOKEN_TTL = Duration.ofMinutes(5);
    private static final int PASSWORD_MAX_LENGTH = 128;
    private static final SecureRandom RNG = new SecureRandom();

    /** 再认证用途 (只进审计, 便于区分是哪个入口在试密码)。 */
    public enum Purpose {
        STEP_UP("step_up"),
        CHANGE_PASSWORD("change_password"),
        IMPERSONATION("impersonation_enter");

        private final String auditName;

        Purpose(String auditName) {
            this.auditName = auditName;
        }
    }

    public record Grant(String stepUpToken, long expiresInSeconds) {}

    private final UserAccountRepository userRepo;
    private final PasswordEncoder passwordEncoder;
    private final AuthSessionService sessions;
    private final SystemSettingsService settings;
    private final NamedParameterJdbcTemplate jdbc;
    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;
    private final String dummyHash;

    public StepUpService(UserAccountRepository userRepo,
                         PasswordEncoder passwordEncoder,
                         AuthSessionService sessions,
                         SystemSettingsService settings,
                         NamedParameterJdbcTemplate jdbc,
                         AuditService audit,
                         SecurityContextCurrentUser currentUser) {
        this.userRepo = userRepo;
        this.passwordEncoder = passwordEncoder;
        this.sessions = sessions;
        this.settings = settings;
        this.jdbc = jdbc;
        this.audit = audit;
        this.currentUser = currentUser;
        this.dummyHash = passwordEncoder.encode("dummy-step-up-timing");
    }

    /** 当前登录员工输入密码, 换取一张本会话专用、5 分钟、一次性的再认证凭证。 */
    public Grant issue(String password) {
        AuthUser principal = requireStaffSession();
        verifyPassword(principal.getId(), principal.getLoginAccount(), password,
                principal.getSessionId(), Purpose.STEP_UP);
        String raw = randomToken();
        Instant expiresAt = sessions.now().plus(TOKEN_TTL);
        if (!sessions.storeStepUp(principal.getSessionId(), principal.getId(),
                HashUtil.sha256(raw), expiresAt)) {
            throw new ApiException(ErrorCode.UNAUTHORIZED);
        }
        return new Grant(raw, TOKEN_TTL.toSeconds());
    }

    /** 核销当前请求携带的凭证 (由 {@code @RequiresStepUp} 拦截器或需要按内容决定的服务调用)。 */
    public void consume(AuthUser principal, String rawToken) {
        if (principal == null || principal.isVisitor() || principal.getImpersonatedBy() != null
                || principal.getSessionId() == null
                || rawToken == null || rawToken.isBlank() || rawToken.length() > 200) {
            throw new ApiException(ErrorCode.REAUTH_REQUIRED);
        }
        if (!sessions.consumeStepUp(principal.getSessionId(), principal.getId(),
                HashUtil.sha256(rawToken.strip()))) {
            throw new ApiException(ErrorCode.REAUTH_REQUIRED);
        }
    }

    /**
     * 需要按请求内容决定是否再认证的写接口用 (如个人资料改手机号/姓名): 从当前请求头取凭证核销。
     * 在调用方事务内核销, 业务随后失败回滚时凭证也随之恢复。
     */
    public void consumeFromCurrentRequest(AuthUser principal) {
        String raw = null;
        if (RequestContextHolder.getRequestAttributes() instanceof ServletRequestAttributes attributes) {
            raw = attributes.getRequest().getHeader(StepUpInterceptor.HEADER);
        }
        consume(principal, raw);
    }

    /**
     * 校验本人密码并计入共享失败计数。暂停期内不校验真实密码 (只跑一次 dummy 哈希抹平时序)。
     * 输错抛 422 REAUTH_FAILED (不用 401, 否则前端会当作登录过期去刷新重放, 一次输错算两次);
     * 达到上限抛 429 REAUTH_LOCKED 并吊销当前会话。
     */
    public void verifyPassword(UUID userId, String loginAccount, String password, UUID sessionId,
                               Purpose purpose) {
        Instant now = sessions.now();
        List<OffsetDateTime> state = failureState(userId);
        Instant lockedUntil = state.isEmpty() || state.getFirst() == null
                ? null : state.getFirst().toInstant();
        if (lockedUntil != null && lockedUntil.isAfter(now)) {
            passwordEncoder.matches(password == null ? "" : truncate(password), dummyHash);
            throw locked(lockedUntil, now);
        }
        UserAccount user = userRepo.findById(userId)
                .filter(row -> !row.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        boolean valid = password != null && !password.isEmpty()
                && password.length() <= PASSWORD_MAX_LENGTH
                && passwordEncoder.matches(password, user.getPasswordHash());
        if (!valid) {
            if (password == null || password.length() > PASSWORD_MAX_LENGTH) {
                passwordEncoder.matches(password == null ? "" : truncate(password), dummyHash);
            }
            throw recordFailure(userId, loginAccount, sessionId, purpose, now);
        }
        if (!state.isEmpty()) {
            clearFailures(userId);
        }
        audit.logExplicit(userId, loginAccount, purpose.auditName + "_verified",
                "users", userId.toString(), "success", sessionId);
    }

    private ApiException recordFailure(UUID userId, String loginAccount, UUID sessionId,
                                       Purpose purpose, Instant now) {
        int threshold = settings.readInt(SystemSettingKey.LOCKOUT_THRESHOLD);
        Instant lockUntil = now.plus(Duration.ofMinutes(settings.readInt(SystemSettingKey.LOCKOUT_MINUTES)));
        // 一条语句完成「暂停已过期则从 1 重新计数, 否则 +1; 到阈值即写暂停截止」, 并发失败不丢计数。
        List<Integer> attempts = jdbc.query("""
                INSERT INTO auth_step_up_states (user_id, failed_attempts, locked_until, updated_at)
                VALUES (:userId, 1, CASE WHEN 1 >= :threshold THEN :lockUntil END, :now)
                ON CONFLICT (user_id) DO UPDATE
                SET failed_attempts = CASE
                        WHEN auth_step_up_states.locked_until IS NOT NULL
                             AND auth_step_up_states.locked_until <= :now THEN 1
                        ELSE auth_step_up_states.failed_attempts + 1 END,
                    locked_until = CASE
                        WHEN (CASE
                                WHEN auth_step_up_states.locked_until IS NOT NULL
                                     AND auth_step_up_states.locked_until <= :now THEN 1
                                ELSE auth_step_up_states.failed_attempts + 1 END) >= :threshold
                        THEN :lockUntil
                        ELSE NULL END,
                    updated_at = :now
                RETURNING failed_attempts
                """,
                new MapSqlParameterSource()
                        .addValue("userId", userId)
                        .addValue("threshold", threshold)
                        .addValue("lockUntil", OffsetDateTime.ofInstant(lockUntil, ZoneOffset.UTC))
                        .addValue("now", OffsetDateTime.ofInstant(now, ZoneOffset.UTC)),
                (rs, rowNum) -> rs.getInt(1));
        int failed = attempts.isEmpty() ? threshold : attempts.getFirst();
        audit.logExplicit(userId, loginAccount, purpose.auditName + "_failed",
                "users", userId.toString(), "bad_password;attempts=" + failed, sessionId);
        if (failed >= threshold) {
            // 暂停验证并踢掉当前会话: 被盗的会话不能继续试密码, 本人重新登录即可。
            sessions.revoke(sessionId, AuthSessionService.REASON_STEP_UP_LOCKED);
            audit.logExplicit(userId, loginAccount, "step_up_locked",
                    "users", userId.toString(), "locked;session_revoked", sessionId);
            return locked(lockUntil, now);
        }
        return new ApiException(ErrorCode.REAUTH_FAILED,
                purpose == Purpose.CHANGE_PASSWORD ? "原密码不正确" : "密码不正确");
    }

    /** 失败计数行 (无行 = 从未输错或已清零); 值是暂停截止 (可为 null)。 */
    private List<OffsetDateTime> failureState(UUID userId) {
        return jdbc.query(
                "SELECT locked_until FROM auth_step_up_states WHERE user_id = :userId",
                new MapSqlParameterSource("userId", userId),
                (rs, rowNum) -> rs.getObject(1, OffsetDateTime.class));
    }

    private void clearFailures(UUID userId) {
        jdbc.update("DELETE FROM auth_step_up_states WHERE user_id = :userId",
                new MapSqlParameterSource("userId", userId));
    }

    private AuthUser requireStaffSession() {
        AuthUser principal = currentUser.get()
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (principal.isVisitor()) {
            throw new ApiException(ErrorCode.FORBIDDEN);
        }
        if (principal.getImpersonatedBy() != null) {
            throw new ApiException(ErrorCode.IMPERSONATION_READ_ONLY,
                    "切换人查看期间不能做需要确认密码的操作，请先退出切换");
        }
        if (principal.getSessionId() == null) {
            throw new ApiException(ErrorCode.UNAUTHORIZED);
        }
        return principal;
    }

    private static ApiException locked(Instant lockedUntil, Instant now) {
        long minutes = Math.max(1, (Duration.between(now, lockedUntil).toSeconds() + 59) / 60);
        return new ApiException(ErrorCode.REAUTH_LOCKED,
                "密码连续输错次数过多，请 " + minutes + " 分钟后再试");
    }

    private static String truncate(String value) {
        return value.length() > PASSWORD_MAX_LENGTH ? value.substring(0, PASSWORD_MAX_LENGTH) : value;
    }

    private static String randomToken() {
        byte[] bytes = new byte[32];
        RNG.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }
}
