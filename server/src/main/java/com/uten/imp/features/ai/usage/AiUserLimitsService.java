package com.uten.imp.features.ai.usage;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashMap;
import java.util.Optional;
import java.util.UUID;

/**
 * AI 助手按人限额与停用(ADR-164, ai_user_limits)。
 *
 * <p>这是运行时门, 不走管理权限: 方法都收 userId 参数(提交人/调用人), 每次任务提交时点查一次。
 * 无行=默认: 不停用、无限额(跟随全局); 因此绝大多数账号零开销之外只多一次 PK 点查,
 * 与 AiChatAccessPolicy 每次部门递归查询同量级, 不做缓存。
 */
@Service
public class AiUserLimitsService {

    /** 一行配置。空限额=跟随全局默认。 */
    public record Limits(UUID userId, boolean disabled, Long dailyTokenLimit, Integer dailyJobLimit, long rowVersion) {}

    /** 管理端写入的 token/job 上限(表列只约束 > 0, 这里的上界防手滑输错量级)。 */
    private static final long MAX_TOKEN_LIMIT = 1_000_000_000_000L;
    private static final int MAX_JOB_LIMIT = 10_000;

    private final NamedParameterJdbcTemplate jdbc;
    private final AuditService audit;

    public AiUserLimitsService(NamedParameterJdbcTemplate jdbc, AuditService audit) {
        this.jdbc = jdbc;
        this.audit = audit;
    }

    /** 无行=默认(不停用、无限额), 调用方按空值处理。 */
    @Transactional(readOnly = true)
    public Optional<Limits> find(UUID userId) {
        return jdbc.query("""
                SELECT user_id,disabled,daily_token_limit,daily_job_limit,row_version
                FROM ai_user_limits WHERE user_id=:userId
                """, new MapSqlParameterSource("userId", userId),
                (rs, row) -> new Limits(rs.getObject("user_id", UUID.class), rs.getBoolean("disabled"),
                        nullableLong(rs, "daily_token_limit"), nullableInt(rs, "daily_job_limit"),
                        rs.getLong("row_version"))).stream().findFirst();
    }

    /** 提交闸: 管理员停用后, 该账号不能再发起任何 AI 任务。 */
    public void requireEnabled(UUID userId) {
        if (userId != null && find(userId).filter(Limits::disabled).isPresent()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "管理员已暂停你的 AI 使用，请联系管理员。");
        }
    }

    /** 该账号的个人每日 token 上限; 空值=无个人限额(按全站预算)。 */
    @Transactional(readOnly = true)
    public Optional<Long> tokenLimit(UUID userId) {
        return userId == null ? Optional.empty() : find(userId).map(Limits::dailyTokenLimit);
    }

    /** 该账号的个人每日任务数上限; null=无个人限额(按全局配置)。 */
    @Transactional(readOnly = true)
    public Integer jobLimitOverride(UUID userId) {
        return userId == null ? null : find(userId).map(Limits::dailyJobLimit).orElse(null);
    }

    /**
     * 管理保存(UPSERT + 乐观锁): {@code expectedVersion < 0} 表示首建(此前无行);
     * 行已存在且版本不匹配时抛 409, 由前端提示刷新。账号不存在抛 404(照人员详情同文案,
     * 防止给幽灵 userId 首建出配置行)。变更随事务写显式审计
     * (行级前后值另由 FULL/authorization 触发器兜底)。
     */
    @Transactional
    public Limits save(UUID userId, boolean disabled, Long tokenLimit, Integer jobLimit, long expectedVersion, UUID actor) {
        if (userId == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "缺少账号");
        if (tokenLimit != null && (tokenLimit < 1 || tokenLimit > MAX_TOKEN_LIMIT)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "每日 token 限额须留空或为 1~" + MAX_TOKEN_LIMIT);
        }
        if (jobLimit != null && (jobLimit < 1 || jobLimit > MAX_JOB_LIMIT)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "每日任务数限额须留空或为 1~" + MAX_JOB_LIMIT);
        }
        Integer existing = jdbc.queryForObject("SELECT count(*) FROM users WHERE id = :userId",
                new MapSqlParameterSource("userId", userId), Integer.class);
        if (existing == null || existing == 0) {
            throw new ApiException(ErrorCode.NOT_FOUND, "账号不存在");
        }
        int inserted = 0;
        if (expectedVersion < 0) {
            inserted = jdbc.update("""
                    INSERT INTO ai_user_limits (user_id,disabled,daily_token_limit,daily_job_limit,updated_by,updated_at)
                    VALUES (:userId,:disabled,:tokenLimit,:jobLimit,:actor,now())
                    ON CONFLICT (user_id) DO NOTHING
                    """, params(userId, disabled, tokenLimit, jobLimit, actor));
        }
        if (inserted == 0) {
            // 行已存在(或首建撞上并发写入): 按版本 CAS 更新, 0 行=别人先保存过。
            int updated = jdbc.update("""
                    UPDATE ai_user_limits SET disabled=:disabled,daily_token_limit=:tokenLimit,
                        daily_job_limit=:jobLimit,row_version=row_version+1,updated_by=:actor,updated_at=now()
                    WHERE user_id=:userId AND row_version=:version
                    """, params(userId, disabled, tokenLimit, jobLimit, actor).addValue("version", expectedVersion));
            if (updated == 0) throw new ApiException(ErrorCode.CONFLICT, "配置有变化，请刷新后再保存");
        }
        Limits saved = find(userId).orElseThrow(() -> new IllegalStateException("ai_user_limits row vanished"));
        var change = new LinkedHashMap<String, Object>();
        change.put("disabled", saved.disabled());
        change.put("dailyTokenLimit", saved.dailyTokenLimit());
        change.put("dailyJobLimit", saved.dailyJobLimit());
        change.put("rowVersion", saved.rowVersion());
        audit.logCommittedChange(actor, null, "update_ai_user_limits", "ai_user_limits", userId.toString(),
                disabled ? "停用账号 AI 使用" : "保存账号 AI 限额", change);
        return saved;
    }

    /** 看板 KPI: 当前被停用的账号数。 */
    @Transactional(readOnly = true)
    public int countDisabled() {
        Integer count = jdbc.queryForObject("SELECT count(*) FROM ai_user_limits WHERE disabled",
                new MapSqlParameterSource(), Integer.class);
        return count == null ? 0 : count;
    }

    private static MapSqlParameterSource params(UUID userId, boolean disabled, Long tokenLimit, Integer jobLimit, UUID actor) {
        return new MapSqlParameterSource("userId", userId).addValue("disabled", disabled)
                .addValue("tokenLimit", tokenLimit).addValue("jobLimit", jobLimit).addValue("actor", actor);
    }

    private static Long nullableLong(java.sql.ResultSet rs, String column) throws java.sql.SQLException {
        long value = rs.getLong(column);
        return rs.wasNull() ? null : value;
    }

    private static Integer nullableInt(java.sql.ResultSet rs, String column) throws java.sql.SQLException {
        int value = rs.getInt(column);
        return rs.wasNull() ? null : value;
    }
}
