package com.uten.imp.features.auth;

import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import lombok.extern.slf4j.Slf4j;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Clock;
import java.time.Duration;
import java.time.temporal.ChronoUnit;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * 服务端会话 (auth_sessions) 的唯一读写入口 (ADR-110)。
 *
 * <p>会话在登录时开启, 绝对期限从登录时刻起算 (系统设置「登录保持时长」), 刷新轮换不延长;
 * 最后活动时间只由人为请求更新且最多 60 秒一次; 登出、改密、重置密码、账号状态变动 (锁定/停用/启用/
 * 解锁/离职/复职)、改登录手机号、远程访问变动、刷新令牌被重放、再认证锁定时吊销。访问令牌的 sid 指向本表, 过滤器每个请求按同一条 SQL 核对账号与会话。</p>
 */
@Slf4j
@Service
public class AuthSessionService {

    /** last_seen_at 的最小更新间隔: 把「每个请求一次写」压到「每分钟至多一次写」。 */
    public static final Duration TOUCH_INTERVAL = Duration.ofSeconds(60);

    public static final String REASON_LOGOUT = "logout";
    public static final String REASON_IDLE = "idle_timeout";
    public static final String REASON_PASSWORD_CHANGED = "password_changed";
    public static final String REASON_ACCOUNT_STATUS = "account_status_changed";
    public static final String REASON_PASSWORD_RESET = "password_reset";
    public static final String REASON_REMOTE_ACCESS = "remote_access_changed";
    public static final String REASON_REFRESH_REUSE = "refresh_reuse";
    public static final String REASON_STEP_UP_LOCKED = "step_up_locked";
    public static final String REASON_LOGIN_ACCOUNT_CHANGED = "login_account_changed";

    private final NamedParameterJdbcTemplate jdbc;
    private final SystemSettingsService settings;
    private final Clock clock;

    public AuthSessionService(NamedParameterJdbcTemplate jdbc, SystemSettingsService settings, Clock clock) {
        this.jdbc = jdbc;
        this.settings = settings;
        this.clock = clock;
    }

    /** 会话判定结果。 */
    public enum Verdict { ACTIVE, MISSING, REVOKED, IDLE_EXPIRED, ABSOLUTE_EXPIRED }

    /** 新开的会话。 */
    public record OpenedSession(UUID sid, OffsetDateTime absoluteExpiresAt) {}

    /** 会话行的判定所需字段。 */
    public record SessionFacts(Instant lastSeenAt, Instant absoluteExpiresAt, Instant revokedAt) {}

    /** 员工账号状态 + 会话 + 空闲阈值 (同一条 SQL 读出)。 */
    public record StaffState(
            UUID employeeId,
            String loginAccount,
            String status,
            boolean mustChangePassword,
            boolean superAdmin,
            boolean remoteAccess,
            boolean deleted,
            long authVersion,
            long authorizationEpoch,
            SessionFacts session,
            String idleTimeoutRaw) {}

    /** 访客账号状态 + 会话 + 空闲阈值 (同一条 SQL 读出)。 */
    public record VisitorState(String status, SessionFacts session, String idleTimeoutRaw) {}

    /**
     * 会话时间一律截到微秒: 与数据库 TIMESTAMPTZ 的精度一致, 否则写进库时被舍入的时刻与内存里
     * 比较用的时刻会差出不到 1 微秒, 恰好卡在空闲阈值边界时判定会随机翻转。
     */
    public Instant now() {
        return clock.instant().truncatedTo(ChronoUnit.MICROS);
    }

    public OpenedSession openStaffSession(UUID userId) {
        return open("user_id", userId);
    }

    public OpenedSession openVisitorSession(UUID visitorId) {
        return open("visitor_id", visitorId);
    }

    private OpenedSession open(String subjectColumn, UUID subjectId) {
        Instant now = now();
        Instant absolute = now.plus(Duration.ofDays(settings.readLong(SystemSettingKey.JWT_REFRESH_TTL_DAYS)));
        UUID sid = UUID.randomUUID();
        jdbc.update("INSERT INTO auth_sessions (sid, " + subjectColumn
                        + ", created_at, last_seen_at, absolute_expires_at)"
                        + " VALUES (:sid, :subject, :now, :now, :absolute)",
                new MapSqlParameterSource()
                        .addValue("sid", sid)
                        .addValue("subject", subjectId)
                        .addValue("now", ts(now))
                        .addValue("absolute", ts(absolute)));
        return new OpenedSession(sid, OffsetDateTime.ofInstant(absolute, ZoneOffset.UTC));
    }

    /**
     * 过滤器用: 一条 SQL 读员工账号状态、授权戳、会话与空闲阈值。
     * {@code sessionOwnerId} 通常就是 {@code userId}; 模拟身份时是发起模拟的超管 (模拟令牌挂在超管会话上)。
     */
    public Optional<StaffState> loadStaff(UUID userId, UUID sid, UUID sessionOwnerId) {
        List<StaffState> rows = jdbc.query("""
                SELECT u.employee_id, u.login_account, u.status, u.must_change_password,
                       u.is_super_admin, u.remote_access, u.is_deleted, u.auth_version,
                       a.epoch AS authorization_epoch,
                       sess.sid AS session_sid, sess.last_seen_at, sess.absolute_expires_at, sess.revoked_at,
                       (SELECT value FROM system_settings WHERE key = :idleKey) AS idle_timeout
                FROM users u
                CROSS JOIN authorization_state a
                LEFT JOIN auth_sessions sess
                       ON sess.sid = :sid AND sess.user_id = :owner
                WHERE u.id = :id
                  AND a.singleton_id = 1
                """,
                new MapSqlParameterSource()
                        .addValue("id", userId)
                        .addValue("sid", sid)
                        .addValue("owner", sessionOwnerId)
                        .addValue("idleKey", SystemSettingKey.SESSION_IDLE_TIMEOUT_MINUTES.key()),
                (rs, rowNum) -> new StaffState(
                        rs.getObject("employee_id", UUID.class),
                        rs.getString("login_account"),
                        rs.getString("status"),
                        rs.getBoolean("must_change_password"),
                        rs.getBoolean("is_super_admin"),
                        rs.getBoolean("remote_access"),
                        rs.getBoolean("is_deleted"),
                        rs.getLong("auth_version"),
                        rs.getLong("authorization_epoch"),
                        sessionFacts(rs),
                        rs.getString("idle_timeout")));
        return rows.stream().findFirst();
    }

    /** 过滤器用: 一条 SQL 读访客账号状态、会话与空闲阈值。 */
    public Optional<VisitorState> loadVisitor(UUID visitorId, UUID sid) {
        List<VisitorState> rows = jdbc.query("""
                SELECT v.status,
                       sess.sid AS session_sid, sess.last_seen_at, sess.absolute_expires_at, sess.revoked_at,
                       (SELECT value FROM system_settings WHERE key = :idleKey) AS idle_timeout
                FROM visitor_accounts v
                LEFT JOIN auth_sessions sess
                       ON sess.sid = :sid AND sess.visitor_id = v.id
                WHERE v.id = :id
                """,
                new MapSqlParameterSource()
                        .addValue("id", visitorId)
                        .addValue("sid", sid)
                        .addValue("idleKey", SystemSettingKey.SESSION_IDLE_TIMEOUT_MINUTES.key()),
                (rs, rowNum) -> new VisitorState(
                        rs.getString("status"), sessionFacts(rs), rs.getString("idle_timeout")));
        return rows.stream().findFirst();
    }

    /** 刷新轮换用: 锁住会话行再判定, 与登出/吊销串行。会话不属于该主体时视为不存在。 */
    public Verdict lockAndEvaluateForRefresh(UUID sid, UUID userId, UUID visitorId) {
        List<SessionFacts> rows = jdbc.query("""
                SELECT sid AS session_sid, last_seen_at, absolute_expires_at, revoked_at
                FROM auth_sessions
                WHERE sid = :sid
                  AND user_id IS NOT DISTINCT FROM :userId
                  AND visitor_id IS NOT DISTINCT FROM :visitorId
                FOR UPDATE
                """,
                new MapSqlParameterSource()
                        .addValue("sid", sid)
                        .addValue("userId", userId, java.sql.Types.OTHER)
                        .addValue("visitorId", visitorId, java.sql.Types.OTHER),
                (rs, rowNum) -> sessionFacts(rs));
        SessionFacts facts = rows.stream().findFirst().orElse(null);
        // 只判定不写: 非 ACTIVE 时调用方抛 401, 刷新事务整体回滚, 在这里落吊销原因也会被一并撤销。
        // 空闲超时的吊销原因由过滤器 (事务外) 在下一次带访问令牌的请求时落库。
        return evaluate(facts, idleTimeoutMinutes(), now());
    }

    /** 判定: 不存在 / 已吊销 / 超绝对期限 / 空闲超时 / 有效。 */
    public static Verdict evaluate(SessionFacts facts, long idleMinutes, Instant now) {
        if (facts == null) {
            return Verdict.MISSING;
        }
        if (facts.revokedAt() != null) {
            return Verdict.REVOKED;
        }
        if (!now.isBefore(facts.absoluteExpiresAt())) {
            return Verdict.ABSOLUTE_EXPIRED;
        }
        if (now.isAfter(facts.lastSeenAt().plus(Duration.ofMinutes(idleMinutes)))) {
            return Verdict.IDLE_EXPIRED;
        }
        return Verdict.ACTIVE;
    }

    /** 同一条 SQL 读出的空闲阈值原值按登记范围解析 (缺失或越界按默认值)。 */
    public static long idleTimeoutMinutes(String raw) {
        return SystemSettingsService.effectiveNumber(SystemSettingKey.SESSION_IDLE_TIMEOUT_MINUTES, raw);
    }

    private long idleTimeoutMinutes() {
        return settings.readInt(SystemSettingKey.SESSION_IDLE_TIMEOUT_MINUTES);
    }

    /**
     * 人为请求续期: 距上次记录已满 {@link #TOUCH_INTERVAL} 才写。条件更新保证并发请求只写一次。
     * 失败只记日志 (例如云端主库暂不可写), 不影响本次请求。
     */
    public void touchIfDue(UUID sid, Instant lastSeenAt, Instant now) {
        if (lastSeenAt != null && lastSeenAt.plus(TOUCH_INTERVAL).isAfter(now)) {
            return;
        }
        try {
            jdbc.update("""
                    UPDATE auth_sessions
                    SET last_seen_at = :now
                    WHERE sid = :sid
                      AND revoked_at IS NULL
                      AND last_seen_at <= :due
                    """,
                    new MapSqlParameterSource()
                            .addValue("sid", sid)
                            .addValue("now", ts(now))
                            .addValue("due", ts(now.minus(TOUCH_INTERVAL))));
        } catch (RuntimeException unavailable) {
            log.warn("会话最后活动时间更新失败 sid={}: {}", sid, unavailable.getMessage());
        }
    }

    /** 吊销一个会话 (幂等), 同时清掉它未用的再认证凭证。在调用方事务内执行, 失败随事务回滚。 */
    public boolean revoke(UUID sid, String reason) {
        if (sid == null) {
            return false;
        }
        return jdbc.update("""
                UPDATE auth_sessions
                SET revoked_at = :now, revoked_reason = :reason,
                    step_up_token_hash = NULL, step_up_expires_at = NULL
                WHERE sid = :sid AND revoked_at IS NULL
                """,
                new MapSqlParameterSource()
                        .addValue("sid", sid)
                        .addValue("now", ts(now()))
                        .addValue("reason", reason)) == 1;
    }

    /**
     * 过滤器发现会话已空闲超时时顺手落一笔吊销原因 (事务外、尽力而为)。
     * 即使写失败, 判定本身已拒绝该请求, 下次判定仍是超时。
     */
    public void revokeQuietly(UUID sid, String reason) {
        try {
            revoke(sid, reason);
        } catch (RuntimeException unavailable) {
            log.warn("会话吊销失败 sid={} reason={}: {}", sid, reason, unavailable.getMessage());
        }
    }

    /** 吊销某员工的全部未吊销会话 (改密、重置、停用、远程访问变动、刷新令牌被重放)。 */
    public int revokeAllForUser(UUID userId, String reason) {
        return jdbc.update("""
                UPDATE auth_sessions
                SET revoked_at = :now, revoked_reason = :reason,
                    step_up_token_hash = NULL, step_up_expires_at = NULL
                WHERE user_id = :userId AND revoked_at IS NULL
                """,
                new MapSqlParameterSource()
                        .addValue("userId", userId)
                        .addValue("now", ts(now()))
                        .addValue("reason", reason));
    }

    /** 吊销某访客的全部未吊销会话 (刷新令牌被重放)。 */
    public int revokeAllForVisitor(UUID visitorId, String reason) {
        return jdbc.update("""
                UPDATE auth_sessions
                SET revoked_at = :now, revoked_reason = :reason
                WHERE visitor_id = :visitorId AND revoked_at IS NULL
                """,
                new MapSqlParameterSource()
                        .addValue("visitorId", visitorId)
                        .addValue("now", ts(now()))
                        .addValue("reason", reason));
    }

    /** 为本会话登记一张新的一次性再认证凭证 (覆盖旧的)。会话已失效时返回 false。 */
    public boolean storeStepUp(UUID sid, UUID userId, String tokenHash, Instant expiresAt) {
        return jdbc.update("""
                UPDATE auth_sessions
                SET step_up_token_hash = :hash, step_up_expires_at = :expires
                WHERE sid = :sid AND user_id = :userId AND revoked_at IS NULL
                """,
                new MapSqlParameterSource()
                        .addValue("sid", sid)
                        .addValue("userId", userId)
                        .addValue("hash", tokenHash)
                        .addValue("expires", ts(expiresAt))) == 1;
    }

    /** 原子地核销再认证凭证: 属于本人本会话、未过期、未用过才成功, 成功即清空 (一次性)。 */
    public boolean consumeStepUp(UUID sid, UUID userId, String tokenHash) {
        return jdbc.update("""
                UPDATE auth_sessions
                SET step_up_token_hash = NULL, step_up_expires_at = NULL
                WHERE sid = :sid
                  AND user_id = :userId
                  AND revoked_at IS NULL
                  AND step_up_token_hash = :hash
                  AND step_up_expires_at > :now
                """,
                new MapSqlParameterSource()
                        .addValue("sid", sid)
                        .addValue("userId", userId)
                        .addValue("hash", tokenHash)
                        .addValue("now", ts(now()))) == 1;
    }

    private static SessionFacts sessionFacts(ResultSet rs) throws SQLException {
        if (rs.getObject("session_sid") == null) {
            return null;
        }
        return new SessionFacts(
                instant(rs.getObject("last_seen_at", OffsetDateTime.class)),
                instant(rs.getObject("absolute_expires_at", OffsetDateTime.class)),
                instant(rs.getObject("revoked_at", OffsetDateTime.class)));
    }

    private static Instant instant(OffsetDateTime value) {
        return value == null ? null : value.toInstant();
    }

    private static OffsetDateTime ts(Instant value) {
        return OffsetDateTime.ofInstant(value, ZoneOffset.UTC);
    }
}
