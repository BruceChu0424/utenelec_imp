package com.uten.imp.features.ai.usage;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.ai.AiProperties;
import com.uten.imp.security.AuthUser;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.YearMonth;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.temporal.ChronoUnit;
import java.util.List;
import java.util.Locale;
import java.util.UUID;

/**
 * AI 用量看板查询(ADR-164): 窗口序列、按人聚合与限额保存。
 *
 * <p>时/日/月/年窗口: 时窗走 ai_call_logs 实时聚合, 日/月/年走 ai_usage_daily 汇总(看板容忍
 * 清理任务最多一个周期的延迟)。全部按上海日/小时划分, 与 todayTokens 同口径, 不依赖数据库会话时区。
 * 读走 REPEATABLE_READ(一次看板的多条查询同一快照); 查看记显式审计, 限额保存的审计由
 * {@link AiUserLimitsService#save} 随事务记录。
 */
@Service
public class AiUsageDashboardService {

    private static final ZoneId SHANGHAI = ZoneId.of("Asia/Shanghai");

    private enum Window { HOUR, DAY, MONTH, YEAR }

    private final NamedParameterJdbcTemplate jdbc;
    private final AiUsageAdminAccess access;
    private final AuditService audit;
    private final AiUserLimitsService limits;
    private final AiProperties properties;

    public AiUsageDashboardService(NamedParameterJdbcTemplate jdbc, AiUsageAdminAccess access, AuditService audit,
                                   AiUserLimitsService limits, AiProperties properties) {
        this.jdbc = jdbc;
        this.access = access;
        this.audit = audit;
        this.limits = limits;
        this.properties = properties;
    }

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ, timeout = 20)
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public AiUsageDtos.Dashboard dashboard(String window) {
        var actor = access.require();
        Window w = parse(window);
        AiUsageDtos.DashboardKpi kpi = jdbc.queryForObject("""
                SELECT coalesce(sum(coalesce(input_tokens,0) + coalesce(output_tokens,0)),0) AS tokens,
                       count(*) AS calls, count(DISTINCT user_id) AS active_users
                FROM ai_call_logs
                WHERE created_at >= date_trunc('day', now() AT TIME ZONE 'Asia/Shanghai') AT TIME ZONE 'Asia/Shanghai'
                """, new MapSqlParameterSource(), (rs, row) -> new AiUsageDtos.DashboardKpi(
                rs.getLong("tokens"), rs.getLong("calls"), rs.getLong("active_users")));
        var result = new AiUsageDtos.Dashboard(w.name().toLowerCase(Locale.ROOT), kpi.todayTokens(),
                properties.getDailyTokenBudget(), kpi.todayCalls(), kpi.activeUsersToday(), limits.countDisabled(),
                series(w), people(w));
        audit.logExplicit(actor.getId(), actor.getLoginAccount(), "view_ai_usage_dashboard", "ai_usage_daily",
                actor.getId().toString(), "查看 AI 用量看板：窗口=" + w.name().toLowerCase(Locale.ROOT));
        return result;
    }

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ, timeout = 20)
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public AiUsageDtos.PersonDetail person(UUID userId, String window) {
        var actor = access.require();
        Window w = parse(window);
        AiUsageDtos.PersonHead head = jdbc.query("""
                SELECT u.id,
                       coalesce(e.full_name, u.login_account, '已删除员工') AS name,
                       coalesce(e.code, '') AS code,
                       d.name AS department
                FROM users u
                LEFT JOIN employees e ON e.id = u.employee_id
                LEFT JOIN departments d ON d.id = e.department_id
                WHERE u.id = :userId
                """, new MapSqlParameterSource("userId", userId), (rs, row) -> new AiUsageDtos.PersonHead(
                rs.getObject("id", UUID.class), rs.getString("name"), rs.getString("code"), rs.getString("department")))
                .stream().findFirst().orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "账号不存在"));
        OffsetDateTime since = callWindowStart(w);
        var byPurpose = jdbc.query("""
                SELECT purpose AS label, count(*) AS calls,
                       sum(coalesce(input_tokens,0) + coalesce(output_tokens,0)) AS tokens
                FROM ai_call_logs
                WHERE user_id = :userId AND created_at >= :since
                GROUP BY purpose ORDER BY count(*) DESC
                """, new MapSqlParameterSource("userId", userId).addValue("since", since),
                (rs, row) -> new AiUsageDtos.Slice(rs.getString("label"), rs.getLong("calls"), rs.getLong("tokens")));
        var byProvider = jdbc.query("""
                SELECT provider_name AS name, count(*) AS calls,
                       sum(coalesce(input_tokens,0) + coalesce(output_tokens,0)) AS tokens
                FROM ai_call_logs
                WHERE user_id = :userId AND created_at >= :since AND provider_name IS NOT NULL
                GROUP BY provider_name ORDER BY count(*) DESC
                """, new MapSqlParameterSource("userId", userId).addValue("since", since),
                (rs, row) -> new AiUsageDtos.Slice(rs.getString("name"), rs.getLong("calls"), rs.getLong("tokens")));
        var recentUses = jdbc.query("""
                SELECT j.id, j.kind, j.audit_question AS question, j.created_at, j.status,
                       (SELECT coalesce(sum(coalesce(c.input_tokens,0) + coalesce(c.output_tokens,0)),0)
                        FROM ai_call_logs c WHERE c.job_id = j.id AND c.user_id = j.submitted_by_user) AS tokens
                FROM ai_jobs j
                WHERE j.submitted_by_user = :userId
                ORDER BY j.created_at DESC, j.id DESC
                LIMIT 20
                """, new MapSqlParameterSource("userId", userId), (rs, row) -> new AiUsageDtos.PersonRecentUse(
                rs.getObject("id", UUID.class), rs.getString("kind"), rs.getString("question"),
                rs.getObject("created_at", OffsetDateTime.class), rs.getString("status"), rs.getLong("tokens")));
        // 今日三值照 dashboard KPI 同口径: call_logs 上海日实时聚合按 userId 过滤 + properties 的全站预算。
        var today = jdbc.queryForObject("""
                SELECT coalesce(sum(coalesce(input_tokens,0) + coalesce(output_tokens,0)),0) AS tokens,
                       count(*) AS calls
                FROM ai_call_logs
                WHERE user_id = :userId
                  AND created_at >= date_trunc('day', now() AT TIME ZONE 'Asia/Shanghai') AT TIME ZONE 'Asia/Shanghai'
                """, new MapSqlParameterSource("userId", userId),
                (rs, row) -> new AiUsageDtos.PersonToday(rs.getLong("tokens"), rs.getLong("calls")));
        var result = new AiUsageDtos.PersonDetail(head.userId(), head.name(), head.code(), head.department(),
                today.todayTokens(), today.todayCalls(), properties.getDailyTokenBudget(),
                limits.find(userId).orElse(null), series(w), byPurpose, byProvider, recentUses);
        audit.logExplicit(actor.getId(), actor.getLoginAccount(), "view_ai_usage_person", "ai_user_limits",
                userId.toString(), "查看 AI 用量人员明细：窗口=" + w.name().toLowerCase(Locale.ROOT));
        return result;
    }

    @Transactional
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public AiUserLimitsService.Limits saveLimits(UUID userId, AiUsageDtos.LimitsRequest request, AuthUser actor) {
        if (request == null || request.disabled() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请先选择是否停用该账号");
        }
        long expectedVersion = request.rowVersion() == null ? -1L : request.rowVersion();
        return limits.save(userId, request.disabled(), request.dailyTokenLimit(), request.dailyJobLimit(),
                expectedVersion, actor.getId());
    }

    private static Window parse(String raw) {
        String value = raw == null || raw.isBlank() ? "day" : raw.strip().toLowerCase(Locale.ROOT);
        return switch (value) {
            case "hour" -> Window.HOUR;
            case "day" -> Window.DAY;
            case "month" -> Window.MONTH;
            case "year" -> Window.YEAR;
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "不支持的统计窗口");
        };
    }

    /** 时窗走实时日志, 日/月/年走日汇总; 空窗格由 generate_series 补零行, 前端不用自己补。 */
    private List<AiUsageDtos.SeriesPoint> series(Window w) {
        var params = new MapSqlParameterSource();
        String sql;
        switch (w) {
            case HOUR -> {
                OffsetDateTime endHour = shanghaiNow().truncatedTo(ChronoUnit.HOURS).toOffsetDateTime();
                params.addValue("startAt", endHour.minusHours(23)).addValue("endAt", endHour);
                sql = """
                        WITH buckets AS (
                          SELECT hour_utc, hour_utc AT TIME ZONE 'Asia/Shanghai' AS local_start,
                                 (hour_utc + interval '1 hour') AS utc_end
                          FROM generate_series(:startAt, :endAt, interval '1 hour') AS hour_utc
                        )
                        SELECT to_char(b.local_start, 'YYYY-MM-DD"T"HH24:00') AS bucket,
                               to_char(b.local_start, 'HH24:00') AS label,
                               coalesce(sum(coalesce(l.input_tokens,0) + coalesce(l.output_tokens,0)),0) AS tokens,
                               count(l.id) AS calls, count(l.id) FILTER (WHERE l.ok) AS ok_calls
                        FROM buckets b LEFT JOIN ai_call_logs l
                          ON l.created_at >= b.hour_utc AND l.created_at < b.utc_end
                        GROUP BY b.hour_utc, b.local_start ORDER BY b.hour_utc
                        """;
            }
            case DAY -> {
                LocalDate today = LocalDate.now(SHANGHAI);
                params.addValue("startDay", today.minusDays(29)).addValue("endDay", today);
                sql = """
                        WITH buckets AS (
                          SELECT day FROM generate_series(:startDay, :endDay, interval '1 day') AS day
                        )
                        SELECT to_char(b.day, 'YYYY-MM-DD') AS bucket, to_char(b.day, 'MM-DD') AS label,
                               coalesce(sum(u.input_tokens + u.output_tokens),0) AS tokens,
                               coalesce(sum(u.calls),0) AS calls, coalesce(sum(u.ok_calls),0) AS ok_calls
                        FROM buckets b LEFT JOIN ai_usage_daily u ON u.usage_date = b.day::date
                        GROUP BY b.day ORDER BY b.day
                        """;
            }
            case MONTH -> {
                LocalDate monthStart = YearMonth.now(SHANGHAI).atDay(1);
                params.addValue("startDay", monthStart.minusMonths(11)).addValue("endDay", monthStart);
                sql = """
                        WITH buckets AS (
                          SELECT month FROM generate_series(:startDay, :endDay, interval '1 month') AS month
                        )
                        SELECT to_char(b.month, 'YYYY-MM') AS bucket, to_char(b.month, 'YYYY-MM') AS label,
                               coalesce(sum(u.input_tokens + u.output_tokens),0) AS tokens,
                               coalesce(sum(u.calls),0) AS calls, coalesce(sum(u.ok_calls),0) AS ok_calls
                        FROM buckets b LEFT JOIN ai_usage_daily u
                          ON u.usage_date >= b.month::date AND u.usage_date < (b.month + interval '1 month')::date
                        GROUP BY b.month ORDER BY b.month
                        """;
            }
            default -> {
                LocalDate yearStart = LocalDate.now(SHANGHAI).withDayOfYear(1);
                params.addValue("startDay", yearStart.minusYears(4)).addValue("endDay", yearStart);
                sql = """
                        WITH buckets AS (
                          SELECT year FROM generate_series(:startDay, :endDay, interval '1 year') AS year
                        )
                        SELECT to_char(b.year, 'YYYY') AS bucket, to_char(b.year, 'YYYY') AS label,
                               coalesce(sum(u.input_tokens + u.output_tokens),0) AS tokens,
                               coalesce(sum(u.calls),0) AS calls, coalesce(sum(u.ok_calls),0) AS ok_calls
                        FROM buckets b LEFT JOIN ai_usage_daily u
                          ON u.usage_date >= b.year::date AND u.usage_date < (b.year + interval '1 year')::date
                        GROUP BY b.year ORDER BY b.year
                        """;
            }
        }
        return jdbc.query(sql, params, (rs, row) -> new AiUsageDtos.SeriesPoint(rs.getString("bucket"),
                rs.getString("label"), rs.getLong("tokens"), rs.getLong("calls"), rs.getLong("ok_calls")));
    }

    /**
     * 窗口内有用量的用户 ∪ 有限额配置的用户, 按窗口消耗降序, 上限 500; 今日值实时取日志。
     * 最近使用按当前窗口口径(时窗=窗口起点, 日/月/年=窗口起点日 0 点, 窗口外不显示);
     * deleted=users 行已删(展示名回退「已删除员工」); rowVersion 下发 COALESCE(row_version,-1) 供乐观锁。
     */
    private List<AiUsageDtos.DashboardPerson> people(Window w) {
        if (w == Window.HOUR) {
            OffsetDateTime endHour = shanghaiNow().truncatedTo(ChronoUnit.HOURS).toOffsetDateTime();
            return jdbc.query("""
                    WITH window_usage AS (
                      SELECT user_id, sum(coalesce(input_tokens,0) + coalesce(output_tokens,0)) AS tokens,
                             count(*) AS calls
                      FROM ai_call_logs WHERE created_at >= :windowStart GROUP BY user_id
                    ), candidates AS (
                      SELECT user_id FROM window_usage UNION SELECT user_id FROM ai_user_limits
                    ), today_usage AS (
                      SELECT user_id, sum(coalesce(input_tokens,0) + coalesce(output_tokens,0)) AS tokens
                      FROM ai_call_logs
                      WHERE created_at >= date_trunc('day', now() AT TIME ZONE 'Asia/Shanghai') AT TIME ZONE 'Asia/Shanghai'
                      GROUP BY user_id
                    ), last_use AS (
                      SELECT user_id, max(created_at) AS last_used_at FROM ai_call_logs
                      WHERE created_at >= :windowStart GROUP BY user_id
                    )
                    SELECT c.user_id,
                           coalesce(e.full_name, u.login_account, '已删除员工') AS name,
                           coalesce(e.code, '') AS code,
                           d.name AS department,
                           (u.id IS NULL) AS deleted,
                           coalesce(l.disabled, false) AS disabled,
                           l.daily_token_limit, l.daily_job_limit,
                           coalesce(l.row_version, -1) AS row_version,
                           coalesce(t.tokens, 0) AS today_tokens,
                           coalesce(w.tokens, 0) AS window_tokens, coalesce(w.calls, 0) AS window_calls,
                           x.last_used_at
                    FROM candidates c
                    LEFT JOIN users u ON u.id = c.user_id
                    LEFT JOIN employees e ON e.id = u.employee_id
                    LEFT JOIN departments d ON d.id = e.department_id
                    LEFT JOIN ai_user_limits l ON l.user_id = c.user_id
                    LEFT JOIN window_usage w ON w.user_id = c.user_id
                    LEFT JOIN today_usage t ON t.user_id = c.user_id
                    LEFT JOIN last_use x ON x.user_id = c.user_id
                    ORDER BY coalesce(w.tokens,0) DESC, c.user_id
                    LIMIT 500
                    """, new MapSqlParameterSource("windowStart", endHour.minusHours(23)),
                    AiUsageDashboardService::person);
        }
        return jdbc.query("""
                WITH window_usage AS (
                  SELECT user_id, sum(input_tokens + output_tokens) AS tokens, sum(calls) AS calls
                  FROM ai_usage_daily WHERE usage_date >= :windowStart GROUP BY user_id
                ), candidates AS (
                  SELECT user_id FROM window_usage UNION SELECT user_id FROM ai_user_limits
                ), today_usage AS (
                  SELECT user_id, sum(coalesce(input_tokens,0) + coalesce(output_tokens,0)) AS tokens
                  FROM ai_call_logs
                  WHERE created_at >= date_trunc('day', now() AT TIME ZONE 'Asia/Shanghai') AT TIME ZONE 'Asia/Shanghai'
                  GROUP BY user_id
                ), last_use AS (
                  SELECT user_id, max(created_at) AS last_used_at FROM ai_call_logs
                  WHERE created_at >= :lastUseStart GROUP BY user_id
                )
                SELECT c.user_id,
                       coalesce(e.full_name, u.login_account, '已删除员工') AS name,
                       coalesce(e.code, '') AS code,
                       d.name AS department,
                       (u.id IS NULL) AS deleted,
                       coalesce(l.disabled, false) AS disabled,
                       l.daily_token_limit, l.daily_job_limit,
                       coalesce(l.row_version, -1) AS row_version,
                       coalesce(t.tokens, 0) AS today_tokens,
                       coalesce(w.tokens, 0) AS window_tokens, coalesce(w.calls, 0) AS window_calls,
                       x.last_used_at
                FROM candidates c
                LEFT JOIN users u ON u.id = c.user_id
                LEFT JOIN employees e ON e.id = u.employee_id
                LEFT JOIN departments d ON d.id = e.department_id
                LEFT JOIN ai_user_limits l ON l.user_id = c.user_id
                LEFT JOIN window_usage w ON w.user_id = c.user_id
                LEFT JOIN today_usage t ON t.user_id = c.user_id
                LEFT JOIN last_use x ON x.user_id = c.user_id
                ORDER BY coalesce(w.tokens,0) DESC, c.user_id
                LIMIT 500
                """, new MapSqlParameterSource("windowStart", dailyWindowStart(w))
                .addValue("lastUseStart", dailyWindowStart(w).atStartOfDay(SHANGHAI).toOffsetDateTime()),
                AiUsageDashboardService::person);
    }

    private static AiUsageDtos.DashboardPerson person(ResultSet rs, int row) throws SQLException {
        return new AiUsageDtos.DashboardPerson(rs.getObject("user_id", UUID.class), rs.getString("name"),
                rs.getString("code"), rs.getString("department"), rs.getBoolean("deleted"),
                rs.getBoolean("disabled"),
                nullableLong(rs, "daily_token_limit"), nullableInt(rs, "daily_job_limit"),
                rs.getLong("today_tokens"), rs.getLong("window_tokens"), rs.getLong("window_calls"),
                rs.getObject("last_used_at", OffsetDateTime.class), rs.getLong("row_version"));
    }

    /** 日汇总窗口的起点(上海日历): 日=近 30 天, 月=近 12 个自然月, 年=近 5 个自然年。 */
    private static LocalDate dailyWindowStart(Window w) {
        return switch (w) {
            case DAY -> LocalDate.now(SHANGHAI).minusDays(29);
            case MONTH -> YearMonth.now(SHANGHAI).minusMonths(11).atDay(1);
            default -> LocalDate.now(SHANGHAI).withDayOfYear(1).minusYears(4);
        };
    }

    /** 调用日志窗口(人员明细的用途/服务商分布)的上海时间起点。 */
    private static OffsetDateTime callWindowStart(Window w) {
        return switch (w) {
            case HOUR -> shanghaiNow().truncatedTo(ChronoUnit.HOURS).toOffsetDateTime().minusHours(23);
            case DAY -> LocalDate.now(SHANGHAI).minusDays(29).atStartOfDay(SHANGHAI).toOffsetDateTime();
            case MONTH -> YearMonth.now(SHANGHAI).minusMonths(11).atDay(1).atStartOfDay(SHANGHAI).toOffsetDateTime();
            default -> LocalDate.now(SHANGHAI).withDayOfYear(1).minusYears(4).atStartOfDay(SHANGHAI).toOffsetDateTime();
        };
    }

    private static ZonedDateTime shanghaiNow() {
        return ZonedDateTime.now(SHANGHAI);
    }

    private static Long nullableLong(ResultSet rs, String column) throws SQLException {
        long value = rs.getLong(column);
        return rs.wasNull() ? null : value;
    }

    private static Integer nullableInt(ResultSet rs, String column) throws SQLException {
        int value = rs.getInt(column);
        return rs.wasNull() ? null : value;
    }
}
