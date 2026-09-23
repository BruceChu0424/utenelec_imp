package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * 真库核对行级审计三清单(ADR-105): 触发器形态逐表等于
 * {@link AuditTriggerCoverageMigrationContractTest} 的清单, fn_audit 只记变化、忽略易变列、
 * 遗留导入旁路、账号脱敏, 审计表按月分区且只追加; 升级时历史审计原样搬进分区表。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class AuditTriggerCoveragePostgresTest {

    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final UUID ACTOR = UUID.randomUUID();
    private static JdbcTemplate db;
    private static long historyBefore;

    @BeforeAll
    static void start() {
        DB.start();
        Flyway.configure().dataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword())
                .locations("classpath:db/migration").target("645").load().migrate();
        db = new JdbcTemplate(new DriverManagerDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword()));
        // 升级前的历史: 在线表一行带完整手机号的操作人, 一行未认证登录失败的原始输入;
        // 旧归档一行三年前的记录。V647 必须原样搬迁并一次性脱敏账号。
        db.update("""
                INSERT INTO audit_log(actor_id, actor_account, action, target_type, target_id, result, event_source)
                VALUES (?, '13800138000', 'update', 'colors', 'history-online', 'success', 'database'),
                       (NULL, 'Secret#Typed', 'login_failed', 'users', NULL, 'account_not_found', 'business')
                """, ACTOR);
        db.update("""
                INSERT INTO audit_log_archive(id, actor_account, action, target_type, target_id, result,
                                              event_source, created_at, risk_level, event_category)
                VALUES (9000000001, '13900139000', 'insert', 'goods', 'history-archived', 'success',
                        'database', now() - interval '36 months', 'low', 'data_change')
                """);
        historyBefore = db.queryForObject(
                "SELECT (SELECT count(*) FROM audit_log) + (SELECT count(*) FROM audit_log_archive)", Long.class);
        Flyway.configure().dataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword())
                .locations("classpath:db/migration").load().migrate();
    }

    @AfterAll
    static void stop() {
        DB.stop();
    }

    @Test
    void upgradeMovesHistoryIntoMonthlyPartitionsAndMasksAccounts() {
        long after = db.queryForObject(
                "SELECT (SELECT count(*) FROM audit_log WHERE target_id LIKE 'history-%' OR action='login_failed')"
                        + " + (SELECT count(*) FROM audit_log_archive)", Long.class);
        assertTrue(after >= 3, "history rows survive the partition conversion");
        assertTrue(db.queryForObject(
                "SELECT (SELECT count(*) FROM audit_log) + (SELECT count(*) FROM audit_log_archive)", Long.class)
                >= historyBefore);
        assertEquals("*******8000", db.queryForObject(
                "SELECT actor_account FROM audit_log WHERE target_id='history-online'", String.class));
        assertNull(db.queryForObject(
                "SELECT actor_account FROM audit_log WHERE action='login_failed' AND result='account_not_found'",
                String.class), "an unverified non-number login input is never stored");
        assertEquals("*******9000", db.queryForObject(
                "SELECT actor_account FROM audit_log_archive WHERE target_id='history-archived'", String.class));
        assertEquals("p", db.queryForObject(
                "SELECT relkind::text FROM pg_class WHERE oid='audit_log'::regclass", String.class));
        assertEquals("p", db.queryForObject(
                "SELECT relkind::text FROM pg_class WHERE oid='audit_log_archive'::regclass", String.class));
        assertEquals(4, db.queryForObject("""
                SELECT count(*) FROM generate_series(0, 3) offset_month
                WHERE to_regclass('public.audit_log_p' || to_char(
                    date_trunc('month', now() AT TIME ZONE 'Asia/Shanghai') + make_interval(months => offset_month),
                    'YYYYMM')) IS NOT NULL
                """, Integer.class), "current month and the next three are pre-created");
        assertEquals(Set.of("audit_log_pk", "idx_audit_log_created", "idx_audit_log_target",
                        "idx_audit_log_request", "idx_audit_log_session", "idx_audit_log_actor"),
                Set.copyOf(db.queryForList(
                        "SELECT indexrelid::regclass::text FROM pg_index WHERE indrelid='audit_log'::regclass",
                        String.class)), "only the indexes the audit pages actually use");
        assertEquals(0, db.queryForObject(
                "SELECT count(*) FROM pg_proc WHERE proname IN ('fn_audit_classify','fn_audit_classify_row','fn_audit_redacted')",
                Integer.class), "classification is computed once at write time");
    }

    @Test
    void catalogMatchesTheThreeListsTableByTable() {
        Map<String, String> full = AuditTriggerCoverageMigrationContractTest.fullTables();
        Set<String> redacted = AuditTriggerCoverageMigrationContractTest.redactedFullTables();
        var scoped = AuditTriggerCoverageMigrationContractTest.scopedTables();
        Set<String> none = AuditTriggerCoverageMigrationContractTest.noneTables();
        List<Map<String, Object>> triggers = db.queryForList("""
                SELECT c.relname, t.tgname, t.tgtype, t.tgqual IS NOT NULL AS has_when, t.tgenabled::text AS enabled,
                       t.tgnargs, encode(t.tgargs, 'escape') AS args,
                       (SELECT string_agg(a.attname, ',' ORDER BY k.ord)
                          FROM unnest(t.tgattr) WITH ORDINALITY k(attnum, ord)
                          JOIN pg_attribute a ON a.attrelid = t.tgrelid AND a.attnum = k.attnum) AS columns
                FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                WHERE NOT t.tgisinternal AND t.tgparentid = 0 AND t.tgfoid = 'public.fn_audit()'::regprocedure
                """);
        Map<String, List<Map<String, Object>>> byTable = new HashMap<>();
        triggers.forEach(row -> byTable.computeIfAbsent((String) row.get("relname"), ignored -> new ArrayList<>()).add(row));

        Set<String> tables = new TreeSet<>(db.queryForList("""
                SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND NOT c.relispartition
                """, String.class));
        Set<String> classified = new TreeSet<>(full.keySet());
        classified.addAll(scoped.keySet());
        classified.addAll(none);
        assertEquals(classified, tables, "every live table is in exactly one list");

        List<String> problems = new ArrayList<>();
        for (String table : tables) {
            List<Map<String, Object>> rows = byTable.getOrDefault(table, List.of());
            if (none.contains(table)) {
                if (!rows.isEmpty()) problems.add(table + " is NONE but audited");
                continue;
            }
            if (full.containsKey(table)) {
                String args = full.get(table) + "\\000" + (redacted.contains(table) ? "redacted" : "plain") + "\\000";
                boolean rowTrigger = rows.stream().anyMatch(row -> ((Number) row.get("tgtype")).intValue() == (1 | 4 | 8)
                        && !(Boolean) row.get("has_when") && args.equals(row.get("args")) && "A".equals(row.get("enabled")));
                boolean updateTrigger = rows.stream().anyMatch(row -> ((Number) row.get("tgtype")).intValue() == (1 | 16)
                        && (Boolean) row.get("has_when") && row.get("columns") == null && args.equals(row.get("args"))
                        && "A".equals(row.get("enabled")));
                if (rows.size() != 2 || !rowTrigger || !updateTrigger) problems.add(table + " FULL shape " + rows);
                continue;
            }
            var policy = scoped.get(table);
            String columns = String.join(",", policy.columns());
            boolean updateTrigger = rows.stream().anyMatch(row -> ((Number) row.get("tgtype")).intValue() == (1 | 16)
                    && (Boolean) row.get("has_when") && columns.equals(row.get("columns")));
            boolean rowTrigger = rows.stream().anyMatch(row -> ((Number) row.get("tgtype")).intValue() == (1 | 4 | 8));
            if (!updateTrigger || rowTrigger != policy.insertDelete() || rows.size() != (policy.insertDelete() ? 2 : 1)) {
                problems.add(table + " COLUMN_SCOPED shape " + rows);
            }
        }
        assertEquals(List.of(), problems);
    }

    @Test
    void updatesStoreOnlyChangedKeysAndSkipNoOpOrVolatileOnlyChanges() throws SQLException {
        UUID color = UUID.randomUUID();
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try (Statement statement = connection.createStatement()) {
                statement.execute("SELECT set_config('app.actor_id','" + ACTOR + "',true),"
                        + " set_config('app.actor_account','13712345678',true)");
                statement.execute("INSERT INTO colors(id, code, name) VALUES('" + color + "','AUD-C1','蓝')");
                statement.execute("UPDATE colors SET name = name WHERE id='" + color + "'");
                statement.execute("UPDATE colors SET updated_at = now() + interval '1 minute' WHERE id='" + color + "'");
                statement.execute("UPDATE colors SET name = '深蓝' WHERE id='" + color + "'");
                statement.execute("UPDATE colors SET is_deleted = TRUE, deleted_at = now() WHERE id='" + color + "'");
                List<String> rows = new ArrayList<>();
                try (var result = statement.executeQuery("""
                        SELECT action || '|' || risk_level || '|' || event_category || '|' ||
                               COALESCE("before"::text, '-') || '|' || COALESCE("after"::text, '-') || '|' || actor_account
                        FROM audit_log WHERE target_type='colors' AND target_id='%s' ORDER BY id
                        """.formatted(color))) {
                    while (result.next()) rows.add(result.getString(1));
                }
                assertEquals(3, rows.size(), "insert, one real change and the soft delete; no-op and volatile-only updates are skipped: " + rows);
                assertTrue(rows.get(0).startsWith("insert|low|data_change|-|") && rows.get(0).contains("\"name\": \"蓝\""));
                assertEquals("update|low|data_change|{\"code\": \"AUD-C1\", \"name\": \"蓝\"}|{\"code\": \"AUD-C1\", \"name\": \"深蓝\"}|*******5678",
                        rows.get(1), "only the changed key plus the locator code, no updated_at");
                assertTrue(rows.get(2).startsWith("delete|high|data_change|") && rows.get(2).contains("\"is_deleted\": false"));
            } finally {
                connection.rollback();
            }
        }
    }

    @Test
    void authorizationRowsAreHighRiskAndLoginAccountsAreMaskedInSnapshots() throws SQLException {
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try (Statement statement = connection.createStatement()) {
                statement.execute("""
                        INSERT INTO employees(id, code, full_name, id_type, department_id, hire_date, status, employment_type)
                        VALUES('%s', 'AUD-EMP', '审计员工', '其他', (SELECT id FROM departments WHERE NOT is_deleted LIMIT 1),
                               DATE '2026-01-01', 'active', 'regular')
                        """.formatted(ACTOR));
                statement.execute("INSERT INTO users(id, employee_id, login_account, password_hash, status)"
                        + " VALUES(gen_random_uuid(), '" + ACTOR + "', '13600001234', 'unused', 'active')");
                // 角色表已随 V655(ADR-109) 删除, 授权类高风险分类改由账号表验证。
                assertEquals("high|authorization", scalar(statement,
                        "SELECT risk_level || '|' || event_category FROM audit_log WHERE target_type='users' AND action='insert'"));
                assertEquals("*******1234", scalar(statement,
                        "SELECT \"after\"->>'login_account' FROM audit_log WHERE target_type='users' AND action='insert'"));
                assertEquals("0", scalar(statement,
                        "SELECT count(*) FROM audit_log WHERE \"after\"::text LIKE '%13600001234%'"));
            } finally {
                connection.rollback();
            }
        }
    }

    /** FULL 表整行与差异都经脱敏函数: 客户/供应商手机与传真、联系方式的值、车牌、证照号、询盘联系人姓名都不进审计。 */
    @Test
    void fullSnapshotsDropContactValuesPlatesAndCertificateNumbers() throws SQLException {
        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            for (String[] probe : new String[][]{
                    {"clients", "{\"code\":\"C1\",\"mobile\":\"13900001111\",\"fax\":\"0571-1\"}", "{\"code\": \"C1\"}"},
                    {"suppliers", "{\"code\":\"S1\",\"mobile\":\"13900001112\"}", "{\"code\": \"S1\"}"},
                    {"party_contact_methods", "{\"kind\":\"PHONE\",\"value\":\"13900001113\",\"is_primary\":true}",
                            "{\"kind\": \"PHONE\", \"is_primary\": true}"},
                    {"employee_vehicles", "{\"plate_no\":\"浙A12345\",\"plate_norm\":\"浙A12345\",\"color\":\"白\"}",
                            "{\"color\": \"白\"}"},
                    {"employee_credentials", "{\"type\":\"电工证\",\"cert_no\":\"T123456\"}", "{\"type\": \"电工证\"}"},
                    {"website_inquiries", "{\"name\":\"王先生\",\"company\":\"外贸公司\"}", "{\"company\": \"外贸公司\"}"}}) {
                assertEquals(probe[2], scalar(statement, "SELECT fn_audit_redact_row('" + probe[0] + "', '"
                        + probe[1] + "'::jsonb)::text"), probe[0]);
            }
        }
    }

    @Test
    void columnScopedPolicyRecordsOnlyTheDeclaredDecisionColumns() throws SQLException {
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try (Statement statement = connection.createStatement()) {
                statement.execute("CREATE TABLE public.audit_scope_probe(id uuid PRIMARY KEY, route text, derived numeric)");
                statement.execute("SELECT fn_audit_track_table('audit_scope_probe', 'COLUMN_SCOPED', 'data_change',"
                        + " false, ARRAY['route'], false)");
                statement.execute("INSERT INTO audit_scope_probe VALUES('" + ACTOR + "', 'MAKE', 1)");
                statement.execute("UPDATE audit_scope_probe SET derived = 2");
                statement.execute("UPDATE audit_scope_probe SET route = 'BUY', derived = 3");
                assertEquals("1", scalar(statement, "SELECT count(*) FROM audit_log WHERE target_type='audit_scope_probe'"));
                assertEquals("{\"route\": \"BUY\"}", scalar(statement,
                        "SELECT \"after\"::text FROM audit_log WHERE target_type='audit_scope_probe'"),
                        "derived columns never enter the scoped audit row");
            } finally {
                connection.rollback();
            }
        }
    }

    @Test
    void legacyImportSessionsBypassRowAuditing() throws SQLException {
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try (Statement statement = connection.createStatement()) {
                statement.execute("SELECT set_config('app.legacy_import', 'on', true)");
                statement.execute("INSERT INTO colors(code, name) VALUES('AUD-LEGACY', '老系统颜色')");
                assertEquals("0", scalar(statement,
                        "SELECT count(*) FROM audit_log WHERE target_type='colors' AND \"after\"->>'code'='AUD-LEGACY'"));
            } finally {
                connection.rollback();
            }
        }
    }

    @Test
    void auditTablesAreAppendOnly() throws SQLException {
        for (String sql : List.of(
                "UPDATE audit_log SET result = 'tampered'",
                "DELETE FROM audit_log",
                "TRUNCATE audit_log",
                "UPDATE audit_log_archive SET result = 'tampered'",
                "DELETE FROM audit_log_archive",
                "TRUNCATE " + db.queryForObject("SELECT c.relname FROM pg_inherits i JOIN pg_class c ON c.oid=i.inhrelid"
                        + " WHERE i.inhparent='audit_log'::regclass LIMIT 1", String.class))) {
            try (Connection connection = connection()) {
                connection.setAutoCommit(false);
                try (Statement statement = connection.createStatement()) {
                    SQLException failure = assertThrows(SQLException.class, () -> statement.execute(sql), sql);
                    assertEquals("42501", failure.getSQLState(), sql);
                } finally {
                    connection.rollback();
                }
            }
        }
    }

    @Test
    void productionPlanCostsIsASingleLegacyOnlyTable() throws SQLException {
        assertEquals("r", db.queryForObject(
                "SELECT relkind::text FROM pg_class WHERE oid='production_plan_costs'::regclass", String.class));
        assertEquals(0, db.queryForObject(
                "SELECT count(*) FROM pg_inherits WHERE inhparent='production_plan_costs'::regclass", Integer.class));
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try (Statement statement = connection.createStatement()) {
                SQLException failure = assertThrows(SQLException.class,
                        () -> statement.execute("DELETE FROM production_plan_costs"));
                assertEquals("42501", failure.getSQLState(), "only the legacy importer writes this read-only snapshot");
            } finally {
                connection.rollback();
            }
            try (Statement statement = connection.createStatement()) {
                statement.execute("SELECT set_config('app.legacy_import', 'on', true)");
                statement.execute("DELETE FROM production_plan_costs");
            } finally {
                connection.rollback();
            }
        }
        assertFalse(db.queryForList("SELECT indexrelid::regclass::text FROM pg_index WHERE indrelid='production_plan_costs'::regclass",
                String.class).isEmpty());
        // 反查「哪些产品用到这个物料」(ProductionWhereUsedQueryService)只走部分覆盖索引, 不扫全表。
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try (Statement statement = connection.createStatement()) {
                statement.execute("SET LOCAL enable_seqscan = off");
                StringBuilder plan = new StringBuilder();
                try (var rows = statement.executeQuery("""
                        EXPLAIN SELECT master_goods_id, sum(qty), sum(pdraw_qty), min(dqty), max(bill_date)
                        FROM production_plan_costs
                        WHERE is_deleted = FALSE AND goods_id = '%s' AND node_class = 0
                          AND master_goods_id IS NOT NULL
                        GROUP BY master_goods_id
                        """.formatted(ACTOR))) {
                    while (rows.next()) plan.append(rows.getString(1)).append('\n');
                }
                assertTrue(plan.toString().contains("idx_ppc_where_used_active"), plan.toString());
            } finally {
                connection.rollback();
            }
        }
    }

    private static String scalar(Statement statement, String sql) throws SQLException {
        try (var result = statement.executeQuery(sql)) {
            return result.next() ? result.getString(1) : null;
        }
    }

    private static Connection connection() throws SQLException {
        return DriverManager.getConnection(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
    }
}
