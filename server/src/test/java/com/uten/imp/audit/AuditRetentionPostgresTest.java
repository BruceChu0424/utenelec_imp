package com.uten.imp.audit;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.MethodOrderer;
import org.junit.jupiter.api.Order;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestMethodOrder;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.ds.PGSimpleDataSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;

/**
 * 审计留存在真库上可证(ADR-105, audit-retention-settings-06/07):
 * 造过期月分区数据 -> 以运行账号执行留存 -> 在线表、归档表、最终删除的行数正确, 且有完成事件;
 * 保留期按系统设置动态读取; 运行账号对审计表没有改删权限, 只能经所有者函数按整月处理。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class AuditRetentionPostgresTest {

    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final ZoneId SHANGHAI = ZoneId.of("Asia/Shanghai");
    private static final String RUNTIME_ROLE = "uten";
    private static final String RUNTIME_PASSWORD = "runtime-test-only";
    private static JdbcTemplate owner;
    private static LocalDate archivableMonth;
    private static LocalDate expiredMonth;
    private static String originalFunctionIdentity;
    private static String seededSnapshot;
    private static List<String> originalHistory;

    @BeforeAll
    static void start() {
        DB.start();
        owner = new JdbcTemplate(new DriverManagerDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword()));
        // 与生产加固脚本同形: 运行账号不是所有者, 先拿通用业务授权, 再由迁移/加固脚本封口审计表。
        owner.execute("CREATE ROLE " + RUNTIME_ROLE + " LOGIN NOSUPERUSER PASSWORD '" + RUNTIME_PASSWORD + "'");
        Flyway.configure().dataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword())
                .locations("classpath:db/migration").target("766").load().migrate();
        owner.execute("GRANT USAGE ON SCHEMA public TO " + RUNTIME_ROLE);
        owner.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO " + RUNTIME_ROLE);
        owner.execute("GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO " + RUNTIME_ROLE);
        owner.execute("GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO " + RUNTIME_ROLE);
        owner.execute("SELECT fn_audit_seal_privileges('" + RUNTIME_ROLE + "')");

        LocalDate currentMonth = LocalDate.now(SHANGHAI).withDayOfMonth(1);
        archivableMonth = currentMonth.minusMonths(10);
        expiredMonth = currentMonth.minusMonths(40);
        for (LocalDate month : List.of(archivableMonth, expiredMonth)) {
            owner.queryForObject("SELECT fn_audit_ensure_partition('audit_log', ?)", String.class, month);
        }
        insertAudit("retention-current", currentMonth.plusDays(1));
        insertAudit("retention-archivable-1", archivableMonth.plusDays(2));
        insertAudit("retention-archivable-2", archivableMonth.plusDays(20));
        insertAudit("retention-expired", expiredMonth.plusDays(5));
        originalFunctionIdentity = functionIdentity();
        originalHistory = owner.queryForList("SELECT version||':'||checksum FROM flyway_schema_history "
                + "WHERE success AND version::integer<=766 ORDER BY installed_rank", String.class);
        seededSnapshot = allSeededRows();
        // The before switch exists solely to reproduce destructive legacy behavior
        // against this throwaway database with the same preservation assertions.
        if (!Boolean.getBoolean("uten.audit.retention.beforeProtection")) {
            Flyway.configure().dataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword())
                    .locations("classpath:db/migration").load().migrate();
        }
    }

    @AfterAll
    static void stop() {
        DB.stop();
    }

    @Test
    @Order(0)
    void forwardProtectionKeepsFunctionPrivilegesHistoryAndExistingEvidence() {
        assertEquals(originalFunctionIdentity, functionIdentity(), "OID, owner and runtime grants survive replacement");
        assertEquals(seededSnapshot, allSeededRows(), "installing protection must not move or remove existing evidence");
        assertEquals(originalHistory, owner.queryForList("SELECT version||':'||checksum FROM flyway_schema_history "
                + "WHERE success AND version::integer<=766 ORDER BY installed_rank", String.class));
        assertTrue(owner.queryForObject("SELECT has_function_privilege(?, 'fn_audit_retention_run()', 'EXECUTE')",
                Boolean.class, RUNTIME_ROLE));
    }

    @Test
    @Order(1)
    void runtimeRoleRetentionMovesWholeMonthsAndLeavesCompletionEvidence() throws Exception {
        long completionsBefore = count("""
                SELECT count(*) FROM audit_log
                WHERE action = 'audit_retention_completed' AND event_source = 'system'
                """);
        // 在线保留期调长到 12 个月: 10 个月前的月份还在线, 40 个月前的整月移入归档但未到最终期限(12+30)。
        setRetention(12, 30);
        AuditRetentionScheduler.RetentionResult first = runtimeScheduler().execute();
        assertTrue(first.lockAcquired());
        assertEquals(1, first.archivedRows());
        assertEquals(List.of(partition("audit_log_archive", expiredMonth)), first.archivedPartitions());
        assertEquals(0, first.droppedRows());
        assertEquals(2, count("SELECT count(*) FROM audit_log WHERE target_id LIKE 'retention-archivable-%'"));

        // 缩短设置仍会归档，但混合历史证据不得仅因年龄被整区删除。
        String onlineSnapshot = snapshot("audit_log");
        setRetention(6, 30);
        AuditRetentionScheduler.RetentionResult second = runtimeScheduler().execute();
        assertEquals(2, second.archivedRows());
        assertEquals(List.of(partition("audit_log_archive", archivableMonth)), second.archivedPartitions());
        assertEquals(0, second.droppedRows());
        assertTrue(second.droppedPartitions().isEmpty());

        assertEquals(1, count("SELECT count(*) FROM audit_log WHERE target_id = 'retention-current'"));
        assertEquals(0, count("SELECT count(*) FROM audit_log WHERE target_id LIKE 'retention-archivable-%'"));
        assertEquals(2, count("SELECT count(*) FROM audit_log_archive WHERE target_id LIKE 'retention-archivable-%'"));
        assertEquals(onlineSnapshot, snapshot("audit_log_archive"),
                "archiving moves whole month partitions, so every column and the jsonb snapshots stay byte-identical");
        assertEquals(1, count("""
                SELECT count(*) FROM audit_log WHERE target_id = 'retention-expired'
                """) + count("SELECT count(*) FROM audit_log_archive WHERE target_id = 'retention-expired'"));
        assertTrue(exists(partition("audit_log_archive", expiredMonth)), "expired mixed evidence stays readable");
        assertFalse(exists(partition("audit_log", archivableMonth)), "archived month left the online table");
        assertTrue(exists(partition("audit_log_archive", archivableMonth)));

        var completion = owner.queryForMap("""
                SELECT actor_account, event_source, risk_level, event_category,
                       "after"->>'archived_rows' AS archived, "after"->>'dropped_rows' AS dropped,
                       "after"->>'hot_months' AS hot, "after"->>'archive_months' AS archive,
                       "after"->>'purge_mode' AS mode,
                       "after"->'preserved_partitions' AS preserved
                FROM audit_log WHERE id = ?
                """, second.completionEventId());
        assertEquals("system", completion.get("actor_account"));
        assertEquals("system", completion.get("event_source"));
        assertEquals("2", completion.get("archived"));
        assertEquals("0", completion.get("dropped"));
        assertEquals("PRESERVE_UNCLASSIFIED", completion.get("mode"));
        assertTrue(completion.get("preserved").toString().contains(partition("audit_log_archive", expiredMonth)));
        assertEquals("6", completion.get("hot"));
        assertEquals("30", completion.get("archive"));
        assertEquals(completionsBefore + 2, count("""
                SELECT count(*) FROM audit_log
                WHERE action = 'audit_retention_completed' AND event_source = 'system'
                """), "every run leaves exactly one completion event");
        assertTrue(new AuditRetentionEvidence(owner).lastCompletedAt().isPresent(),
                "the server status page can read the last successful run");
    }

    @Test
    @Order(2)
    void runtimeRoleCannotRewriteOrDeleteAuditEvidence() throws SQLException {
        for (String sql : List.of(
                "UPDATE audit_log SET result = 'tampered'",
                "DELETE FROM audit_log",
                "TRUNCATE audit_log",
                "UPDATE audit_log_archive SET result = 'tampered'",
                "DELETE FROM audit_log_archive",
                "DROP TABLE " + partition("audit_log", LocalDate.now(SHANGHAI).withDayOfMonth(1)),
                "UPDATE " + partition("audit_log", LocalDate.now(SHANGHAI).withDayOfMonth(1))
                        + " SET result = 'tampered'")) {
            try (Connection connection = runtimeConnection(); Statement statement = connection.createStatement()) {
                SQLException failure = assertThrows(SQLException.class, () -> statement.execute(sql), sql);
                assertEquals("42501", failure.getSQLState(), sql);
            }
        }
        try (Connection connection = runtimeConnection(); Statement statement = connection.createStatement()) {
            statement.execute("""
                    INSERT INTO audit_log(action, target_type, target_id, result, event_source, risk_level, event_category)
                    VALUES ('probe', 'probe', 'runtime-append', 'success', 'business', 'low', 'business')
                    """);
        }
        assertEquals(1, count("SELECT count(*) FROM audit_log WHERE target_id = 'runtime-append'"),
                "the runtime role can still append");
    }

    @Test
    @Order(3)
    void archivePartitionsCannotPreemptCurrentOrFutureMonths() {
        LocalDate currentMonth = LocalDate.now(SHANGHAI).withDayOfMonth(1);
        var failure = assertThrows(Exception.class, () -> owner.queryForObject(
                "SELECT fn_audit_ensure_partition('audit_log_archive', ?)", String.class, currentMonth.plusMonths(2)));
        assertTrue(failure.getMessage().contains("archive partitions only hold past months"));
    }

    /**
     * 运行账号能改系统设置, 但压不破函数里的法定下限(在线 + 归档合计 6 个月):
     * 把设置改成 1/0 后仍保留最短6个月边界，超过该边界也只登记候选、不销毁混合证据。
     * 另一个会话占着审计表时, 分区 DDL 最多等 5 秒就放弃, 不做任何改动。
     */
    @Test
    @Order(10)
    void runtimeRoleCannotLowerRetentionBelowTheLegalFloorAndDdlNeverQueuesForever() throws Exception {
        LocalDate currentMonth = LocalDate.now(SHANGHAI).withDayOfMonth(1);
        LocalDate recentMonth = currentMonth.minusMonths(3);
        LocalDate oldMonth = currentMonth.minusMonths(8);
        for (LocalDate month : List.of(recentMonth, oldMonth)) {
            owner.queryForObject("SELECT fn_audit_ensure_partition('audit_log', ?)", String.class, month);
        }
        insertAudit("floor-recent", recentMonth.plusDays(3));
        insertAudit("floor-old", oldMonth.plusDays(3));
        try (Connection runtime = runtimeConnection(); Statement statement = runtime.createStatement()) {
            statement.executeUpdate("UPDATE system_settings SET value = '1' WHERE key = 'audit_hot_retention_months'");
            statement.executeUpdate("UPDATE system_settings SET value = '0' WHERE key = 'audit_archive_retention_months'");
        }

        try (Connection blocker = DriverManager.getConnection(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
             Statement hold = blocker.createStatement()) {
            blocker.setAutoCommit(false);
            hold.execute("LOCK TABLE audit_log IN ACCESS SHARE MODE");
            long started = System.nanoTime();
            SQLException blocked = assertThrows(SQLException.class, () -> runtimeScheduler().execute());
            long waitedMillis = (System.nanoTime() - started) / 1_000_000;
            assertEquals("55P03", blocked.getSQLState(), "lock_not_available, not an indefinite queue");
            assertTrue(waitedMillis < 15_000, "gave up after the 5 second lock budget, waited " + waitedMillis);
            blocker.rollback();
        }
        assertTrue(exists(partition("audit_log", recentMonth)), "a blocked run changes nothing");
        assertTrue(exists(partition("audit_log", oldMonth)));

        AuditRetentionScheduler.RetentionResult run = runtimeScheduler().execute();
        assertEquals(1, run.hotMonths());
        assertEquals(5, run.archiveMonths(), "effective archive months are lifted to the 6 month floor");
        assertTrue(run.archivedPartitions().contains(partition("audit_log_archive", recentMonth)));
        assertTrue(run.droppedPartitions().isEmpty());
        assertEquals(0, run.droppedRows());
        assertEquals(1, count("SELECT count(*) FROM audit_log_archive WHERE target_id = 'floor-recent'"));
        assertEquals(1, count("SELECT count(*) FROM audit_log WHERE target_id = 'floor-old'")
                + count("SELECT count(*) FROM audit_log_archive WHERE target_id = 'floor-old'"));
        var completion = owner.queryForMap("""
                SELECT "after"->>'configured_hot_months' AS hot, "after"->>'configured_archive_months' AS archive,
                       "after"->>'archive_months' AS effective, "after"->>'floor_applied' AS floor,
                       "after"->'preserved_partitions' AS preserved,
                       "after"->>'purge_mode' AS mode
                FROM audit_log WHERE id = ?
                """, run.completionEventId());
        assertEquals("1", completion.get("hot"));
        assertEquals("0", completion.get("archive"));
        assertEquals("5", completion.get("effective"));
        assertEquals("true", completion.get("floor"));
        assertEquals("PRESERVE_UNCLASSIFIED", completion.get("mode"));
        assertTrue(completion.get("preserved").toString().contains(partition("audit_log_archive", oldMonth)));
        assertFalse(completion.get("preserved").toString().contains(partition("audit_log_archive", recentMonth)));
        assertEquals(1, count("""
                SELECT count(*) FROM pg_constraint
                WHERE conrelid = ('public.' || '%s')::regclass AND conname = 'audit_month_bound' AND convalidated
                """.formatted(partition("audit_log_archive", recentMonth))),
                "the month bound was validated before the exclusive DDL, so ATTACH skipped its scan");
        setRetention(6, 30);
    }

    @Test
    @Order(11)
    void repeatedRunsPreserveExactEvidenceAndDoNotRescanArchivedRows() throws Exception {
        String before = owner.queryForObject("SELECT string_agg(to_jsonb(a)::text,'|' ORDER BY id) "
                + "FROM audit_log_archive a", String.class);
        var first = runtimeScheduler().execute();
        var second = runtimeScheduler().execute();
        assertEquals(0, first.droppedRows());
        assertEquals(0, second.droppedRows());
        assertEquals(before, owner.queryForObject("SELECT string_agg(to_jsonb(a)::text,'|' ORDER BY id) "
                + "FROM audit_log_archive a", String.class));
        // A BEFORE SELECT hook is unavailable in PostgreSQL; inspect the installed
        // function's archive-only loop, alongside actual row-preservation assertions.
        String definition = owner.queryForObject("SELECT pg_get_functiondef('fn_audit_retention_run()'::regprocedure)", String.class);
        int archiveStart = definition.indexOf("'public.audit_log_archive'::regclass");
        String archiveLoop = definition.substring(archiveStart, definition.indexOf("END LOOP;", archiveStart));
        assertFalse(archiveLoop.contains("count(*)"), "daily preservation must not count decades of retained archive rows");
        assertFalse(definition.contains("DROP TABLE"));
    }

    private static String functionIdentity() {
        return owner.queryForObject("SELECT jsonb_build_object('oid',oid,'owner',proowner,'acl',proacl,"
                + "'security_definer',prosecdef,'settings',proconfig,"
                + "'result',pg_get_function_result(oid),'arguments',pg_get_function_arguments(oid))::text "
                + "FROM pg_proc WHERE oid='fn_audit_retention_run()'::regprocedure", String.class);
    }

    @Test
    @Order(12)
    void expiredMonthContainingBusinessSecurityAndTechnicalEvidenceIsPreservedTogether() throws Exception {
        LocalDate month = LocalDate.now(SHANGHAI).withDayOfMonth(1).minusMonths(50);
        owner.queryForObject("SELECT fn_audit_ensure_partition('audit_log', ?)", String.class, month);
        insertAudit("mixed-business", month.plusDays(1), "business", "business");
        insertAudit("mixed-security", month.plusDays(2), "security", "security");
        insertAudit("mixed-technical", month.plusDays(3), "request", "system");
        String before = owner.queryForObject("SELECT string_agg(to_jsonb(a)::text,'|' ORDER BY id) "
                + "FROM audit_log a WHERE target_id LIKE 'mixed-%'", String.class);
        setRetention(6, 0);
        var run = runtimeScheduler().execute();
        assertEquals(0, run.droppedRows());
        assertTrue(run.archivedPartitions().contains(partition("audit_log_archive", month)));
        assertEquals(before, owner.queryForObject("SELECT string_agg(to_jsonb(a)::text,'|' ORDER BY id) "
                + "FROM audit_log_archive a WHERE target_id LIKE 'mixed-%'", String.class));
        var evidence = owner.queryForMap("SELECT \"after\"->'preserved_partitions' AS partitions, "
                + "\"after\"->>'preserved_partition_count' AS total FROM audit_log WHERE id=?", run.completionEventId());
        assertTrue(evidence.get("partitions").toString().contains(partition("audit_log_archive", month)));
        assertTrue(Integer.parseInt(evidence.get("total").toString()) >= 1);
        setRetention(6, 30);
    }

    @Test
    @Order(13)
    void readOnlyCapabilityTracksInstalledProtectionAndRejectsFunctionDrift() throws Exception {
        long eventsBefore = count("SELECT count(*) FROM audit_log");
        try (Connection connection = runtimeConnection(); Statement statement = connection.createStatement()) {
            try (var rows = statement.executeQuery("SELECT fn_audit_retention_purge_mode()")) {
                assertTrue(rows.next());
                assertEquals("PRESERVE_UNCLASSIFIED", rows.getString(1));
            }
        }
        assertEquals(eventsBefore, count("SELECT count(*) FROM audit_log"), "capability read cannot execute retention");
        String original = owner.queryForObject("SELECT pg_get_functiondef('fn_audit_retention_run()'::regprocedure)", String.class);
        try {
            owner.execute(original.replace("'PRESERVE_UNCLASSIFIED'", "'DRIFTED_TEST_POLICY'"));
            assertEquals("UNKNOWN", owner.queryForObject("SELECT fn_audit_retention_purge_mode()", String.class));
        } finally {
            owner.execute(original);
        }
        assertEquals("PRESERVE_UNCLASSIFIED", owner.queryForObject("SELECT fn_audit_retention_purge_mode()", String.class));
    }

    private static String allSeededRows() {
        return owner.queryForObject("SELECT string_agg(to_jsonb(a)::text,'|' ORDER BY id) "
                + "FROM audit_log a WHERE target_id LIKE 'retention-%'", String.class);
    }

    private static AuditRetentionScheduler runtimeScheduler() {
        PGSimpleDataSource runtime = new PGSimpleDataSource();
        runtime.setURL(DB.getJdbcUrl());
        runtime.setUser(RUNTIME_ROLE);
        runtime.setPassword(RUNTIME_PASSWORD);
        return new AuditRetentionScheduler(runtime, mock(AuditService.class));
    }

    private static void setRetention(int hotMonths, int archiveMonths) {
        owner.update("UPDATE system_settings SET value = ? WHERE key = 'audit_hot_retention_months'",
                Integer.toString(hotMonths));
        owner.update("UPDATE system_settings SET value = ? WHERE key = 'audit_archive_retention_months'",
                Integer.toString(archiveMonths));
    }

    private static void insertAudit(String targetId, LocalDate day) {
        insertAudit(targetId, day, "database", "data_change");
    }

    private static void insertAudit(String targetId, LocalDate day, String source, String category) {
        owner.update("""
                INSERT INTO audit_log(action, target_type, target_id, result, event_source,
                                      risk_level, event_category, created_at, "before", "after")
                VALUES ('update', 'retention_test', ?, 'success', ?, 'low', ?,
                        (?::date + time '10:00') AT TIME ZONE 'Asia/Shanghai',
                        '{"quantity": 1.2345, "bill_no": "RT-1"}', '{"quantity": 12.3456, "bill_no": "RT-1"}')
                """, targetId, source, category, day);
    }

    /** 两个父表列序相同(归档表按在线表 LIKE 建), 整行 to_jsonb 相等即完整快照原样保留。 */
    private static String snapshot(String parent) {
        return owner.queryForObject("SELECT string_agg(to_jsonb(h)::text, '|' ORDER BY h.id) FROM "
                + parent + " h WHERE h.target_id LIKE 'retention-archivable-%'", String.class);
    }

    private static String partition(String parent, LocalDate month) {
        return parent + "_p" + month.format(DateTimeFormatter.ofPattern("yyyyMM"));
    }

    private static boolean exists(String relation) {
        return Boolean.TRUE.equals(owner.queryForObject(
                "SELECT to_regclass('public.' || ?) IS NOT NULL", Boolean.class, relation));
    }

    private static long count(String sql) {
        return owner.queryForObject(sql, Long.class);
    }

    private static Connection runtimeConnection() throws SQLException {
        return DriverManager.getConnection(DB.getJdbcUrl(), RUNTIME_ROLE, RUNTIME_PASSWORD);
    }
}
