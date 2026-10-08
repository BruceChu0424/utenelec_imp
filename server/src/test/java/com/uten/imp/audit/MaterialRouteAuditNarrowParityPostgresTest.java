package com.uten.imp.audit;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * V830 窄投影路线审计的金样等值测试(ADR-105/ADR-107):
 * 同一张探针表 route_audit_parity_probe、同一组确定性更新, 分别挂通用 {@code fn_audit}
 * 与专用 {@code fn_audit_route_columns} 各跑一遍, 审计行必须逐字段一致——
 * 覆盖三列同变/单列变/NULL 补齐/清确认/同值更新/非审计列/混合批量/upsert 冲突更新。
 * 每次运行以唯一 {@code app.audit_request_id} 圈定自己的审计行(审计表只追加, 不删行)。
 * 另外钉死真实 {@code production_material_analysis_materials} 上的登记形态:
 * 行级、ENABLE ALWAYS、指向窄函数。
 *
 * <p>窄函数省掉的是通用机制(整行 to_jsonb x2 + 全列 diff + minimize x3), 语义等值
 * 由本测试锁定; 若有人改了窄函数或通用函数导致语义漂移, 这里必须红。</p>
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MaterialRouteAuditNarrowParityPostgresTest {

    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate db;
    private static final UUID ACTOR = UUID.randomUUID();
    private static final UUID CONFIRMER = UUID.randomUUID();
    private static final UUID OTHER_CONFIRMER = UUID.randomUUID();

    @BeforeAll
    static void start() {
        DB.start();
        db = new JdbcTemplate(new DriverManagerDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword()));
        Flyway.configure().dataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword())
                .locations("classpath:db/migration").load().migrate();
        db.execute("""
                CREATE TABLE route_audit_parity_probe (
                    id uuid PRIMARY KEY,
                    confirmed_route text,
                    route_reason text,
                    route_confirmed_by uuid,
                    route_confirmed_at timestamptz,
                    available_qty numeric,
                    updated_at timestamptz DEFAULT now())
                """);
        db.update("""
                INSERT INTO route_audit_parity_probe(id, available_qty)
                SELECT gen_random_uuid(), g FROM generate_series(1, 30) g
                """);
    }

    @AfterAll
    static void stop() {
        DB.stop();
    }

    /** 两种审计函数在同一矩阵下产生的审计行投影。 */
    private record AuditRow(String action, String targetId, String actorId, String before, String after,
                            String riskLevel, String eventCategory, String ip, String userAgent,
                            String result, String eventSource) {}

    private List<AuditRow> runMatrixUnder(String updateFn) throws SQLException {
        db.query("""
                SELECT public.fn_audit_track_table('route_audit_parity_probe', 'COLUMN_SCOPED', 'data_change', false,
                    ARRAY['confirmed_route', 'route_reason', 'route_confirmed_by'], false, ?)
                """, row -> { /* single void cell */ }, updateFn);
        resetProbeState();
        UUID requestId = UUID.randomUUID();
        // 与生产 TxSessionVars 同一传递方式: 单连接事务内 set_config, 触发器经 current_setting 读取。
        try (var connection = DriverManager.getConnection(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword())) {
            connection.setAutoCommit(false);
            var tx = new JdbcTemplate(new SingleConnectionDataSource(connection, true));
            tx.query("SELECT set_config(?, ?, true)", row -> { /* value only */ },
                    "app.actor_id", ACTOR.toString());
            tx.query("SELECT set_config(?, ?, true)", row -> { /* value only */ },
                    "app.actor_account", "parity@uten.test");
            tx.query("SELECT set_config(?, ?, true)", row -> { /* value only */ },
                    "app.audit_ip", "127.0.0.8");
            tx.query("SELECT set_config(?, ?, true)", row -> { /* value only */ },
                    "app.audit_user_agent", "parity-test");
            tx.query("SELECT set_config(?, ?, true)", row -> { /* value only */ },
                    "app.audit_request_id", requestId.toString());
            runMatrixUpdates(tx);
            connection.commit();
        }
        return db.query("""
                SELECT action, target_id::text, actor_id::text, before::text, after::text,
                       risk_level, event_category, ip, user_agent, result, event_source
                FROM audit_log
                WHERE target_type = 'route_audit_parity_probe' AND request_id = ?
                ORDER BY target_id, id
                """,
                (rs, i) -> new AuditRow(rs.getString(1), rs.getString(2), rs.getString(3), rs.getString(4),
                        rs.getString(5), rs.getString(6), rs.getString(7), rs.getString(8), rs.getString(9),
                        rs.getString(10), rs.getString(11)), requestId);
    }

    private void resetProbeState() {
        db.update("""
                UPDATE route_audit_parity_probe
                SET confirmed_route = NULL, route_reason = NULL, route_confirmed_by = NULL,
                    route_confirmed_at = NULL, updated_at = now()
                """);
        db.update("""
                UPDATE route_audit_parity_probe
                SET confirmed_route = 'BUY', route_reason = ?, route_confirmed_by = ?,
                    route_confirmed_at = now(), updated_at = now()
                WHERE id IN (SELECT id FROM route_audit_parity_probe ORDER BY id LIMIT 10)
                """, "初始采购路线", CONFIRMER);
    }

    private void runMatrixUpdates(JdbcTemplate tx) {
        tx.update("""
                UPDATE route_audit_parity_probe
                SET confirmed_route = 'MAKE', route_reason = ?, route_confirmed_by = ?, updated_at = now()
                WHERE confirmed_route = 'BUY' AND id =
                    (SELECT id FROM route_audit_parity_probe WHERE confirmed_route = 'BUY' ORDER BY id LIMIT 1)
                """, "改为自制", OTHER_CONFIRMER);
        tx.update("""
                UPDATE route_audit_parity_probe
                SET confirmed_route = 'SUBCONTRACT', updated_at = now()
                WHERE confirmed_route = 'BUY' AND id =
                    (SELECT id FROM route_audit_parity_probe WHERE confirmed_route = 'BUY' ORDER BY id LIMIT 1)
                """);
        tx.update("""
                UPDATE route_audit_parity_probe
                SET route_reason = ?, updated_at = now()
                WHERE confirmed_route = 'BUY' AND id =
                    (SELECT id FROM route_audit_parity_probe WHERE confirmed_route = 'BUY' ORDER BY id LIMIT 1)
                """, "委外商产能不足, 改回采购并保留原供应商折扣协议长期有效并继续沿用历史价格条款");
        tx.update("""
                UPDATE route_audit_parity_probe
                SET confirmed_route = 'MAKE', route_reason = ?, route_confirmed_by = ?, updated_at = now()
                WHERE confirmed_route IS NULL AND id =
                    (SELECT id FROM route_audit_parity_probe WHERE confirmed_route IS NULL ORDER BY id LIMIT 1)
                """, "补确认", OTHER_CONFIRMER);
        tx.update("""
                UPDATE route_audit_parity_probe SET available_qty = available_qty + 1, updated_at = now()
                """);
        tx.update("""
                UPDATE route_audit_parity_probe SET confirmed_route = 'BUY', updated_at = now()
                WHERE confirmed_route = 'BUY'
                """);
        tx.update("""
                UPDATE route_audit_parity_probe
                SET confirmed_route = 'MAKE', route_reason = ?, route_confirmed_by = ?, updated_at = now()
                WHERE id IN (SELECT id FROM route_audit_parity_probe ORDER BY id LIMIT 7)
                """, "批量改自制", OTHER_CONFIRMER);
        tx.update("""
                INSERT INTO route_audit_parity_probe(id, confirmed_route)
                VALUES ((SELECT id FROM route_audit_parity_probe ORDER BY id LIMIT 1), 'SUBCONTRACT')
                ON CONFLICT (id) DO UPDATE
                SET confirmed_route = EXCLUDED.confirmed_route, updated_at = now()
                """);
        tx.update("""
                UPDATE route_audit_parity_probe
                SET confirmed_route = NULL, route_reason = NULL, route_confirmed_by = NULL,
                    route_confirmed_at = NULL, updated_at = now()
                WHERE route_reason = ?
                """, "批量改自制");
        // 混合语句: 审计列与非审计列同语句变化——通用版全列 diff 再 scope 过滤, 窄函数只比 3 列, 最易分叉的路径。
        tx.update("""
                UPDATE route_audit_parity_probe
                SET available_qty = available_qty + 7, confirmed_route = 'BUY', updated_at = now()
                WHERE id = (SELECT id FROM route_audit_parity_probe ORDER BY id LIMIT 1)
                """);
        // 审计三列之外的时间戳单独变化: 两种函数都必须 0 行。
        tx.update("""
                UPDATE route_audit_parity_probe
                SET route_confirmed_at = now() + interval '1 hour', updated_at = now()
                WHERE confirmed_route = 'BUY'
                """);
        // route_reason 单列回 NULL(值到 NULL 的单列退化)。
        tx.update("""
                UPDATE route_audit_parity_probe
                SET route_reason = NULL, updated_at = now()
                WHERE confirmed_route = 'BUY' AND id =
                    (SELECT id FROM route_audit_parity_probe ORDER BY id LIMIT 1)
                """);
    }

    @Test
    void narrowProjectionMatchesGenericAuditRowForRow() throws SQLException {
        List<AuditRow> generic = runMatrixUnder(null);
        List<AuditRow> narrow = runMatrixUnder("public.fn_audit_route_columns()");
        assertEquals(generic.size(), narrow.size(),
                "行数不一致: generic=" + generic.size() + " narrow=" + narrow.size());
        assertEquals(generic, narrow, "窄投影审计行必须与通用 fn_audit 逐字段一致");
        assertTrue(generic.size() >= 15, "矩阵必须真实产生足够多的审计行, 实际=" + generic.size());
        assertTrue(generic.stream().allMatch(row -> ACTOR.toString().equals(row.actorId())),
                "两种函数都必须从事务会话变量读取操作人");
    }

    @Test
    void materialsTableRegistersTheNarrowRowLevelAlwaysTrigger() {
        List<String[]> triggers = db.query("""
                SELECT t.tgfoid::regproc::text, (t.tgtype & 1)::text, t.tgenabled::text,
                       (SELECT string_agg(a.attname, ',' ORDER BY k.ord)
                          FROM unnest(t.tgattr) WITH ORDINALITY k(attnum, ord)
                          JOIN pg_attribute a ON a.attrelid = t.tgrelid AND a.attnum = k.attnum) AS columns,
                       (t.tgqual IS NOT NULL)::text
                FROM pg_trigger t
                WHERE t.tgrelid = 'production_material_analysis_materials'::regclass
                  AND NOT t.tgisinternal AND t.tgname LIKE 'trg_audit%'
                """,
                (rs, i) -> new String[] {rs.getString(1), rs.getString(2), rs.getString(3),
                        rs.getString(4), rs.getString(5)});
        assertEquals(1, triggers.size(), "路线审计只有一个 UPDATE 触发器, 实际=" + triggers);
        String[] trigger = triggers.get(0);
        assertEquals("fn_audit_route_columns", trigger[0], "UPDATE 审计必须指向窄函数");
        assertEquals("1", trigger[1], "必须是行级触发器");
        assertEquals("A", trigger[2], "必须 ENABLE ALWAYS");
        // 列清单必须与窄函数硬编码的三列一致: 未来再登记若漂移, 窄函数会静默吞掉多出列的审计。
        assertEquals("confirmed_route,route_reason,route_confirmed_by", trigger[3],
                "UPDATE OF 列清单必须与窄函数的审计三列一致");
        assertEquals("true", trigger[4], "必须带 WHEN 门(任一审计列真变才起跳)");
    }

    /** legacy_import 旁路对窄函数必须生效(0 行): 离线导入不逐行复制历史。 */
    @Test
    void legacyImportBypassAppliesToTheNarrowFunction() throws SQLException {
        db.query("""
                SELECT public.fn_audit_track_table('route_audit_parity_probe', 'COLUMN_SCOPED', 'data_change', false,
                    ARRAY['confirmed_route', 'route_reason', 'route_confirmed_by'], false, ?)
                """, row -> { /* single void cell */ }, "public.fn_audit_route_columns()");
        resetProbeState();
        UUID requestId = UUID.randomUUID();
        try (var connection = DriverManager.getConnection(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword())) {
            connection.setAutoCommit(false);
            var tx = new JdbcTemplate(new SingleConnectionDataSource(connection, true));
            tx.query("SELECT set_config(?, ?, true)", row -> { /* value only */ },
                    "app.actor_id", ACTOR.toString());
            tx.query("SELECT set_config(?, ?, true)", row -> { /* value only */ },
                    "app.audit_request_id", requestId.toString());
            tx.query("SELECT set_config(?, ?, true)", row -> { /* value only */ },
                    "app.legacy_import", "on");
            tx.update("""
                    UPDATE route_audit_parity_probe
                    SET confirmed_route = 'MAKE', route_reason = ?, route_confirmed_by = ?, updated_at = now()
                    WHERE id = (SELECT id FROM route_audit_parity_probe ORDER BY id LIMIT 1)
                    """, "离线导入期间的路线变化", OTHER_CONFIRMER);
            connection.commit();
        }
        Integer rows = db.queryForObject("""
                SELECT count(*) FROM audit_log
                WHERE target_type = 'route_audit_parity_probe' AND request_id = ?
                """, Integer.class, requestId);
        assertEquals(0, rows, "app.legacy_import=on 时窄函数必须 0 审计行");
    }
}
