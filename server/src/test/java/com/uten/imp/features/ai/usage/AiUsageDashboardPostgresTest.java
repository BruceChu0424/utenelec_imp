package com.uten.imp.features.ai.usage;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.ai.AiProperties;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;

/**
 * V815 (ADR-164) 用量看板聚合: 日汇总窗口序列、时窗实时日志、按人并集、rollup 幂等与人员 404,
 * 全部跑在真实迁移库上(迁移含 V815 的两张表, 建表与回填随 Flyway 前进, 不接受旧基线静默回退)。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class AiUsageDashboardPostgresTest {

    private static final ZoneId SHANGHAI = ZoneId.of("Asia/Shanghai");
    private static final DateTimeFormatter HOUR_LABEL = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:00");

    static MigratedSchemaBaseline.ScopedDatabase database;
    static JdbcTemplate jdbc;
    static NamedParameterJdbcTemplate named;
    AiUsageDashboardService dashboard;
    AiUsageDailyService daily;

    @BeforeAll
    static void open() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("ai_usage_dashboard");
        var dataSource = new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(),
                database.getPassword());
        jdbc = new JdbcTemplate(dataSource);
        named = new NamedParameterJdbcTemplate(jdbc);
        // 本回归跟随 V815: 两张表必须由真实迁移建出。
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM information_schema.tables
                WHERE table_schema = 'public' AND table_name IN ('ai_user_limits', 'ai_usage_daily')
                """, Integer.class)).isEqualTo(2);
    }

    @AfterAll
    static void close() throws Exception {
        SecurityContextHolder.clearContext();
        if (database != null) {
            database.close();
        }
    }

    @BeforeEach
    void setUp() {
        // call_logs 的 DELETE 被生命周期触发器改写成归档软删(V778), 行留在表里会串用例;
        // 照 AiCallLogResetGenerationPostgresTest 先例走业务重置的 TRUNCATE 通道清账。
        // ai_usage_daily 随重置 CLEAR; ai_user_limits 登记 PRESERVE, 需手动清。
        jdbc.queryForList("SELECT * FROM business_data_reset()");
        jdbc.update("DELETE FROM ai_user_limits");
        loginAsSuperAdmin();
        dashboard = new AiUsageDashboardService(named, new AiUsageAdminAccess(new SecurityContextCurrentUser()),
                mock(AuditService.class), new AiUserLimitsService(named, mock(AuditService.class)),
                new AiProperties());
        daily = new AiUsageDailyService(named);
    }

    private void loginAsSuperAdmin() {
        var actor = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "admin",
                Set.of("authorization:manage"), false, true, true);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(actor, null, actor.getAuthorities()));
    }

    // ------------------------------------------------------------------ 夹具

    private UUID user(String label) {
        String tag = label + UUID.randomUUID().toString().substring(0, 8);
        UUID employeeId = UUID.randomUUID();
        UUID userId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees(id, code, full_name, id_type, department_id, hire_date, status, employment_type)
                SELECT ?, ?, '用量看板测试', '其他', id, CURRENT_DATE, 'active', 'regular'
                FROM departments WHERE code = 'DEPT_FIN'
                """, employeeId, "UD-" + tag);
        jdbc.update("""
                INSERT INTO users(id, employee_id, login_account, password_hash, must_change_password, status)
                VALUES (?, ?, ?, 'test-only', false, 'active')
                """, userId, employeeId, "ud-" + tag);
        return userId;
    }

    private void dailyRow(UUID userId, LocalDate date, int calls, int okCalls, long inputTokens, long outputTokens) {
        jdbc.update("""
                INSERT INTO ai_usage_daily (user_id, usage_date, calls, ok_calls, input_tokens, output_tokens)
                VALUES (?, ?, ?, ?, ?, ?)
                """, userId, date, calls, okCalls, inputTokens, outputTokens);
    }

    private void limitsRow(UUID userId, boolean disabled, Long tokenLimit, Integer jobLimit) {
        jdbc.update("""
                INSERT INTO ai_user_limits (user_id, disabled, daily_token_limit, daily_job_limit)
                VALUES (?, ?, ?, ?)
                """, userId, disabled, tokenLimit, jobLimit);
    }

    private void callLog(UUID userId, boolean ok, Integer inputTokens, Integer outputTokens,
                         OffsetDateTime createdAt) {
        jdbc.update("""
                INSERT INTO ai_call_logs (purpose, provider_name, model, protocol, ok, input_tokens, output_tokens,
                                          latency_ms, user_id, created_at)
                VALUES ('USAGE_DASHBOARD_TEST', 'Test AI', 'test-model', 'OPENAI_CHAT', ?, ?, ?, 5, ?, ?)
                """, ok, inputTokens, outputTokens, userId, createdAt);
    }

    // ------------------------------------------------------------------ 用例

    @Test
    void dayAndMonthWindowsAggregateTheDailyRollupTable() {
        LocalDate today = LocalDate.now(SHANGHAI);
        UUID a = user("day-a");
        UUID b = user("day-b");
        dailyRow(a, today.minusDays(3), 2, 1, 100, 50);
        dailyRow(a, today.minusDays(1), 1, 1, 10, 5);
        dailyRow(b, today, 3, 2, 200, 100);

        var day = dashboard.dashboard("day");
        assertThat(day.window()).isEqualTo("day");
        assertThat(day.dailyTokenBudget()).isEqualTo(new AiProperties().getDailyTokenBudget());
        assertThat(day.series()).hasSize(30);
        assertThat(day.series().get(0).bucket()).isEqualTo(today.minusDays(29).toString());
        assertThat(day.series().get(29).bucket()).isEqualTo(today.toString());
        assertThat(pointOfDay(day, today.minusDays(3)))
                .satisfies(p -> {
                    assertThat(p.tokens()).isEqualTo(150L);
                    assertThat(p.calls()).isEqualTo(2L);
                    assertThat(p.okCalls()).isEqualTo(1L);
                });
        assertThat(pointOfDay(day, today.minusDays(2)).tokens()).isZero();
        assertThat(pointOfDay(day, today.minusDays(2)).calls()).isZero();
        assertThat(pointOfDay(day, today).tokens()).isEqualTo(300L);
        assertThat(pointOfDay(day, today).calls()).isEqualTo(3L);
        assertThat(pointOfDay(day, today).okCalls()).isEqualTo(2L);
        // 没有实时日志: 今日 KPI 全零。
        assertThat(day.todayTokens()).isZero();
        assertThat(day.todayCalls()).isZero();
        assertThat(day.activeUsersToday()).isZero();
        assertThat(day.disabledCount()).isZero();

        var month = dashboard.dashboard("month");
        assertThat(month.window()).isEqualTo("month");
        assertThat(month.series()).hasSize(12);
        assertThat(month.series().get(11).bucket()).isEqualTo(today.withDayOfMonth(1).toString().substring(0, 7));
        assertThat(month.series()).allSatisfy(p -> assertThat(p.bucket()).matches("\\d{4}-\\d{2}"));
        assertThat(month.series().stream().mapToLong(AiUsageDtos.SeriesPoint::tokens).sum()).isEqualTo(465L);
        assertThat(month.series().stream().mapToLong(AiUsageDtos.SeriesPoint::calls).sum()).isEqualTo(6L);
        assertThat(month.series().stream().mapToLong(AiUsageDtos.SeriesPoint::okCalls).sum()).isEqualTo(4L);
    }

    @Test
    void theHourWindowReadsLiveCallLogsInsteadOfTheDailyRollup() {
        UUID a = user("hour-a");
        ZonedDateTime currentHour = ZonedDateTime.now(SHANGHAI).truncatedTo(ChronoUnit.HOURS);
        OffsetDateTime nowBucket = currentHour.toOffsetDateTime().plusMinutes(10);
        OffsetDateTime olderBucket = currentHour.minusHours(3).toOffsetDateTime().plusMinutes(30);
        LocalDate today = LocalDate.now(SHANGHAI);
        callLog(a, true, 30, 10, nowBucket);
        callLog(a, false, 5, 2, nowBucket);
        callLog(a, true, 7, 3, olderBucket);

        var hour = dashboard.dashboard("hour");
        assertThat(hour.window()).isEqualTo("hour");
        assertThat(hour.series()).hasSize(24);
        assertThat(pointByInstant(hour, nowBucket.toInstant()).tokens()).isEqualTo(47L);
        assertThat(pointByInstant(hour, nowBucket.toInstant()).calls()).isEqualTo(2L);
        assertThat(pointByInstant(hour, nowBucket.toInstant()).okCalls()).isEqualTo(1L);
        assertThat(pointByInstant(hour, olderBucket.toInstant()).tokens()).isEqualTo(10L);
        assertThat(pointByInstant(hour, olderBucket.toInstant()).okCalls()).isEqualTo(1L);

        // 当前小时桶永远落在上海「今天」; 三小时前的桶可能已跨到昨天。
        boolean olderBucketIsToday = olderBucket.atZoneSameInstant(SHANGHAI).toLocalDate().equals(today);
        assertThat(hour.todayTokens()).isEqualTo(47L + (olderBucketIsToday ? 10L : 0L));
        assertThat(hour.todayCalls()).isEqualTo(2L + (olderBucketIsToday ? 1L : 0L));
        assertThat(hour.activeUsersToday()).isEqualTo(1L);
    }

    @Test
    void peopleCoversUsersWithUsageAndUsersWithOnlyALimitsRow() {
        LocalDate today = LocalDate.now(SHANGHAI);
        UUID spender = user("people-spender");
        UUID limited = user("people-limited");
        UUID stranger = user("people-stranger");
        dailyRow(spender, today.minusDays(1), 4, 3, 400, 100);
        limitsRow(limited, true, 5000L, 50);

        var day = dashboard.dashboard("day");
        assertThat(day.disabledCount()).isEqualTo(1L);
        assertThat(day.people()).hasSize(2).extracting(AiUsageDtos.DashboardPerson::userId)
                .containsExactlyInAnyOrder(spender, limited);

        AiUsageDtos.DashboardPerson spenderRow = personOf(day, spender);
        assertThat(spenderRow.name()).isEqualTo("用量看板测试");
        assertThat(spenderRow.deleted()).isFalse();
        assertThat(spenderRow.disabled()).isFalse();
        assertThat(spenderRow.dailyTokenLimit()).isNull();
        assertThat(spenderRow.dailyJobLimit()).isNull();
        assertThat(spenderRow.rowVersion()).isEqualTo(-1L);
        assertThat(spenderRow.windowTokens()).isEqualTo(500L);
        assertThat(spenderRow.windowCalls()).isEqualTo(4L);

        AiUsageDtos.DashboardPerson limitedRow = personOf(day, limited);
        assertThat(limitedRow.deleted()).isFalse();
        assertThat(limitedRow.disabled()).isTrue();
        assertThat(limitedRow.dailyTokenLimit()).isEqualTo(5000L);
        assertThat(limitedRow.dailyJobLimit()).isEqualTo(50);
        assertThat(limitedRow.rowVersion()).isZero();
        assertThat(limitedRow.windowTokens()).isZero();
        assertThat(limitedRow.windowCalls()).isZero();
        assertThat(limitedRow.todayTokens()).isZero();
        assertThat(limitedRow.lastUsedAt()).isNull();

        assertThat(day.people()).extracting(AiUsageDtos.DashboardPerson::userId)
                .doesNotContain(stranger);
    }

    @Test
    void rollupBackfillsFullDaysRecomputesRecentDaysAndIsIdempotent() {
        LocalDate today = LocalDate.now(SHANGHAI);
        UUID a = user("roll-a");
        OffsetDateTime yesterdayNoon = today.minusDays(1).atTime(12, 0).atZone(SHANGHAI).toOffsetDateTime();
        OffsetDateTime todayMorning = today.atTime(9, 0).atZone(SHANGHAI).toOffsetDateTime();
        callLog(a, true, 100, 40, yesterdayNoon);
        callLog(a, false, 10, 5, todayMorning);
        callLog(a, true, 1, 1, todayMorning);

        var first = daily.rollup();
        // 昨天与今天都由 refresh 覆盖(upsert); 回填只管昨天之前的缺口, 这里没有。
        assertThat(first.backfilled()).isZero();
        assertThat(first.refreshed()).isEqualTo(2);
        assertThat(dailyTable()).containsExactly(
                a + "|" + today.minusDays(1) + "|1|1|100|40",
                a + "|" + today + "|2|1|11|6");

        var second = daily.rollup();
        assertThat(second.backfilled()).isZero();
        assertThat(dailyTable()).containsExactly(
                a + "|" + today.minusDays(1) + "|1|1|100|40",
                a + "|" + today + "|2|1|11|6");

        // 汇总后日窗口序列立刻反映归档值。
        assertThat(pointOfDay(dashboard.dashboard("day"), today).tokens()).isEqualTo(17L);
        assertThat(pointOfDay(dashboard.dashboard("day"), today).calls()).isEqualTo(2L);
    }

    @Test
    void rollupCorrectsYesterdaysTailWhenLogsArriveAfterTheMidnightRun() {
        LocalDate today = LocalDate.now(SHANGHAI);
        UUID a = user("roll-tail");
        OffsetDateTime yesterdayNoon = today.minusDays(1).atTime(12, 0).atZone(SHANGHAI).toOffsetDateTime();
        OffsetDateTime todayMorning = today.atTime(9, 0).atZone(SHANGHAI).toOffsetDateTime();
        callLog(a, true, 100, 40, yesterdayNoon);
        callLog(a, true, 1, 1, todayMorning);

        var first = daily.rollup();
        assertThat(first.backfilled()).isZero();
        assertThat(first.refreshed()).isEqualTo(2);
        assertThat(dailyTable()).containsExactly(
                a + "|" + today.minusDays(1) + "|1|1|100|40",
                a + "|" + today + "|1|1|1|1");

        // 昨天深夜的日志在上次 rollup 之后才落账(跨天尾巴): 回填是 DO NOTHING, 只有
        // 次日 refresh 的覆盖更新能把尾巴并进昨天的最终值。
        OffsetDateTime yesterdayLateNight = today.minusDays(1).atTime(23, 55).atZone(SHANGHAI).toOffsetDateTime();
        callLog(a, true, 50, 25, yesterdayLateNight);

        var second = daily.rollup();
        assertThat(second.backfilled()).isZero();
        assertThat(second.refreshed()).isEqualTo(2);
        assertThat(dailyTable()).containsExactly(
                a + "|" + today.minusDays(1) + "|2|2|150|65",
                a + "|" + today + "|1|1|1|1");
    }

    @Test
    void personDetailCarriesTodayKpiAndBudgetFromLiveLogs() {
        LocalDate today = LocalDate.now(SHANGHAI);
        UUID a = user("person-today");
        callLog(a, true, 1200, 300, today.atTime(10, 0).atZone(SHANGHAI).toOffsetDateTime());
        callLog(a, false, 0, 0, today.atTime(11, 0).atZone(SHANGHAI).toOffsetDateTime());

        var detail = dashboard.person(a, "day");
        assertThat(detail.todayTokens()).isEqualTo(1500L);
        assertThat(detail.todayCalls()).isEqualTo(2L);
        assertThat(detail.dailyTokenBudget()).isEqualTo(new AiProperties().getDailyTokenBudget());
    }

    @Test
    void personDetailForAMissingAccountIs404() {
        assertThatThrownBy(() -> dashboard.person(UUID.randomUUID(), "day"))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> {
                    assertThat(((ApiException) error).getCode()).isEqualTo(ErrorCode.NOT_FOUND);
                    assertThat(error.getMessage()).contains("账号不存在");
                });
    }

    // ------------------------------------------------------------------ 小工具

    private static AiUsageDtos.SeriesPoint pointOfDay(AiUsageDtos.Dashboard dashboard, LocalDate date) {
        return dashboard.series().stream()
                .filter(point -> point.bucket().equals(date.toString())).findFirst().orElseThrow();
    }

    private static AiUsageDtos.SeriesPoint pointByInstant(AiUsageDtos.Dashboard dashboard,
                                                          java.time.Instant instant) {
        // 时窗 bucket 带完整日期(YYYY-MM-DD"THH:00), label 只有 HH:00——按 bucket 对齐。
        String bucket = HOUR_LABEL.withZone(SHANGHAI).format(instant);
        return dashboard.series().stream()
                .filter(point -> point.bucket().equals(bucket)).findFirst().orElseThrow();
    }

    private static AiUsageDtos.DashboardPerson personOf(AiUsageDtos.Dashboard dashboard, UUID userId) {
        return dashboard.people().stream()
                .filter(person -> person.userId().equals(userId)).findFirst().orElseThrow();
    }

    private List<String> dailyTable() {
        return jdbc.query("""
                SELECT user_id::text || '|' || usage_date::text || '|' || calls || '|' || ok_calls
                       || '|' || input_tokens || '|' || output_tokens
                FROM ai_usage_daily ORDER BY usage_date, user_id
                """, (rs, row) -> rs.getString(1));
    }
}
