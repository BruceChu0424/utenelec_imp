package com.uten.imp.features.stock;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.Statement;
import java.sql.ResultSet;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTimeoutPreemptively;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * 货架目视化清单查询（PostgreSQL 集成测试，testcontainers + 全量 Flyway 迁移，原生 JDBC）。
 *
 * <p>跑的是 {@link ShelfLabelSql} 产出的<b>同一份 SQL 文本</b>（命名参数按出现顺序换成 {@code ?}），
 * 验证：三段解析与 {@link ShelfPlaceParser} 一致、残值归未分层且排最后、禁用默认不列、
 * 选仓时本仓树偏好优先 + 仓树余额、未选仓全部核算仓余额、rack 过滤只对已分层行生效、
 * layout 末尾未分层桶、racks 只回已分层库行。
 *
 * <p>不启 Spring，只验 SQL 语义；与 {@link SalesReservationSafetyStockPostgresTest} 同款骨架。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ShelfLabelQueryPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    /** 命名参数（:name）；排除 PostgreSQL 的 ::cast。 */
    private static final Pattern NAMED_PARAM = Pattern.compile("(?<!:):([A-Za-z]\\w*)");

    @BeforeAll
    static void migrate() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void rowsParseThreeSegmentsHideDisabledByDefaultAndSumAccountableBalances() {
        assertTimeoutPreemptively(Duration.ofSeconds(30), () -> {
            try (Connection c = connection()) {
                Fixture f = Fixture.create(c);

                List<Map<String, Object>> rows = query(c,
                        ShelfLabelSql.rows(false, false, false, false), Map.of());

                List<UUID> ids = rows.stream().map(r -> (UUID) r.get("goods_id")).toList();
                assertTrue(ids.contains(f.parsedA30), "A30-1-2 已分层行应出现");
                assertTrue(ids.contains(f.parsedA31), "A31-1-1 已分层行应出现");
                assertTrue(ids.contains(f.residue), "残值 Y12 仍应出现（归未分层桶）");
                assertFalse(ids.contains(f.disabled), "禁用货品默认不列");
                assertFalse(ids.contains(f.noPlace), "无库位号不列");
                assertFalse(ids.contains(f.deleted), "软删不列");

                Map<String, Object> a30 = rowOf(rows, f.parsedA30);
                assertEquals(Boolean.TRUE, a30.get("parsed"));
                assertEquals("A30-1-2", a30.get("place"));
                assertEquals(0, ((java.math.BigDecimal) a30.get("qty")).compareTo(new java.math.BigDecimal("12")),
                        "未选仓 = 全部核算仓余额汇总（5 + 7，非核算仓 3 不计）");
                assertEquals("个", a30.get("unit_name"));
                assertEquals(Boolean.FALSE, a30.get("disabled"));

                Map<String, Object> residue = rowOf(rows, f.residue);
                assertEquals(Boolean.FALSE, residue.get("parsed"));
                assertEquals("Y12", residue.get("place"));
                assertEquals(0, ((java.math.BigDecimal) residue.get("qty")).signum());

                // SQL parsed 标记与 Java 解析器一致；已分层在前、残值最后。
                for (Map<String, Object> r : rows) {
                    String place = (String) r.get("place");
                    assertEquals(ShelfPlaceParser.parse(place).parsed(), r.get("parsed"),
                            "SQL parsed 与 ShelfPlaceParser 不一致：" + place);
                }
                int firstUnparsed = -1;
                for (int i = 0; i < rows.size(); i++) {
                    if (Boolean.FALSE.equals(rows.get(i).get("parsed"))) {
                        firstUnparsed = i;
                        break;
                    }
                }
                for (int i = firstUnparsed; i >= 0 && i < rows.size(); i++) {
                    assertEquals(Boolean.FALSE, rows.get(i).get("parsed"), "残值必须排在全部已分层行之后");
                }
                assertTrue(indexOf(rows, f.parsedA30) < indexOf(rows, f.parsedA31), "库行 A30 在 A31 之前");

                // includeDisabled=true：禁用行出现且 disabled=true。
                List<Map<String, Object>> withDisabled = query(c,
                        ShelfLabelSql.rows(false, true, false, false), Map.of());
                Map<String, Object> disabledRow = rowOf(withDisabled, f.disabled);
                assertEquals(Boolean.TRUE, disabledRow.get("disabled"));
                assertEquals("A30-2-1", disabledRow.get("place"));
            }
        });
    }

    @Test
    void rackFilterOnlyMatchesParsedRowsAndKeywordMatchesPlace() {
        assertTimeoutPreemptively(Duration.ofSeconds(30), () -> {
            try (Connection c = connection()) {
                Fixture f = Fixture.create(c);

                List<Map<String, Object>> a30 = query(c,
                        ShelfLabelSql.rows(false, true, true, false), Map.of("rack", "A30"));
                List<UUID> ids = a30.stream().map(r -> (UUID) r.get("goods_id")).toList();
                assertTrue(ids.contains(f.parsedA30));
                assertTrue(ids.contains(f.disabled), "含禁用时 A30-2-1 也在 A30 库行");
                assertFalse(ids.contains(f.parsedA31));
                assertFalse(ids.contains(f.residue), "残值 Y12 不参与库行筛选");
                assertTrue(indexOf(a30, f.parsedA30) < indexOf(a30, f.disabled), "同库行按层升序：1 层在 2 层前");

                List<Map<String, Object>> byPlace = query(c,
                        ShelfLabelSql.rows(false, false, false, true), Map.of("kw", "%y12%"));
                assertEquals(1, byPlace.stream().filter(r -> f.residue.equals(r.get("goods_id"))).count(),
                        "关键字对库位号 ILIKE（大小写不敏感）");
            }
        });
    }

    @Test
    void warehouseScopeUsesSubtreePreferenceAndSubtreeBalances() {
        assertTimeoutPreemptively(Duration.ofSeconds(30), () -> {
            try (Connection c = connection()) {
                Fixture f = Fixture.create(c);

                List<Map<String, Object>> rows = query(c,
                        ShelfLabelSql.rows(true, false, false, false), Map.of("warehouseId", f.parentWh));

                Map<String, Object> a30 = rowOf(rows, f.parsedA30);
                assertEquals(0, ((java.math.BigDecimal) a30.get("qty")).compareTo(new java.math.BigDecimal("5")),
                        "选父仓 = 该仓及子仓余额（子仓 5），其他仓 7 不计");
                Map<String, Object> a31 = rowOf(rows, f.parsedA31);
                assertEquals("B01-3-4", a31.get("place"), "选仓时子仓学习到的偏好库位优先于主档 A31-1-1");
                assertEquals(Boolean.TRUE, a31.get("parsed"));
                assertEquals(0, ((java.math.BigDecimal) a31.get("qty")).compareTo(new java.math.BigDecimal("1")));
                assertTrue(rows.stream().anyMatch(r -> f.prefOnly.equals(r.get("goods_id"))),
                        "主档无库位但本仓有偏好的货品，选仓时应出现");
                assertFalse(rows.stream().anyMatch(r -> f.prefOnly.equals(r.get("goods_id"))
                        && !"C02-1-1".equals(r.get("place"))));

                List<Map<String, Object>> otherWh = query(c,
                        ShelfLabelSql.rows(true, false, false, false), Map.of("warehouseId", f.otherWh));
                assertEquals("A31-1-1", rowOf(otherWh, f.parsedA31).get("place"), "别的仓没有偏好 → 回落主档");
                assertFalse(otherWh.stream().anyMatch(r -> f.prefOnly.equals(r.get("goods_id"))),
                        "偏好只属于学习到的那棵仓树");
                assertEquals(0, ((java.math.BigDecimal) rowOf(otherWh, f.parsedA30).get("qty"))
                        .compareTo(new java.math.BigDecimal("7")));
            }
        });
    }

    @Test
    void layoutAggregatesRacksAndAppendsUnparsedBucketLast() {
        assertTimeoutPreemptively(Duration.ofSeconds(30), () -> {
            try (Connection c = connection()) {
                Fixture f = Fixture.create(c);

                List<Map<String, Object>> layout = query(c, ShelfLabelSql.layout(false, true), Map.of());
                Map<String, Object> a30 = layout.stream()
                        .filter(r -> "A30".equals(r.get("rack"))).findFirst().orElseThrow();
                assertEquals(2, ((Number) a30.get("max_level")).intValue(), "A30-1-2 + A30-2-1 → 最大层 2");
                assertEquals(2, ((Number) a30.get("max_slot")).intValue());
                assertTrue(((Number) a30.get("cnt")).longValue() >= 2);

                Map<String, Object> last = layout.get(layout.size() - 1);
                assertEquals("", last.get("rack"), "未分层桶在末尾，rack 为空串");
                assertNull(last.get("max_level"));
                assertTrue(((Number) last.get("cnt")).longValue() >= 1, "残值 Y12 计入未分层桶");
                assertEquals(1, layout.stream().filter(r -> "".equals(r.get("rack"))).count());

                List<Map<String, Object>> racks = query(c, ShelfLabelSql.racks(false, false), Map.of());
                List<Object> names = racks.stream().map(r -> r.get("rack")).toList();
                assertTrue(names.contains("A30"));
                assertTrue(names.contains("A31"));
                assertFalse(names.contains(""), "racks 不含未分层");
                assertFalse(names.contains("Y12"), "残值不再冒充库行进下拉");
            }
        });
    }

    // ------------------------------------------------------------------ helpers

    /** 每个用例独立造一套数据（唯一编码后缀），互不干扰。 */
    private record Fixture(UUID parentWh, UUID childWh, UUID otherWh, UUID nonAccountableWh,
                           UUID parsedA30, UUID parsedA31, UUID residue, UUID disabled,
                           UUID noPlace, UUID deleted, UUID prefOnly) {

        static Fixture create(Connection c) throws Exception {
            String salt = UUID.randomUUID().toString().substring(0, 8);
            UUID parent = insertWarehouse(c, "SHELF-P-" + salt, null, true);
            UUID child = insertWarehouse(c, "SHELF-C-" + salt, parent, true);
            UUID other = insertWarehouse(c, "SHELF-O-" + salt, null, true);
            UUID nonAcc = insertWarehouse(c, "SHELF-N-" + salt, null, false);
            UUID unit = insertUnit(c, "个-" + salt);

            UUID a30 = insertGoods(c, "SG-A30-" + salt, "A30-1-2", "使用", false, unit);
            UUID a31 = insertGoods(c, "SG-A31-" + salt, "A31-1-1", "使用", false, unit);
            UUID residue = insertGoods(c, "SG-Y12-" + salt, "Y12", "使用", false, unit);
            UUID disabled = insertGoods(c, "SG-DIS-" + salt, "A30-2-1", "禁用", false, unit);
            UUID noPlace = insertGoods(c, "SG-NOP-" + salt, "   ", "使用", false, unit);
            UUID deleted = insertGoods(c, "SG-DEL-" + salt, "A39-1-1", "使用", true, unit);
            UUID prefOnly = insertGoods(c, "SG-PRF-" + salt, null, "使用", false, unit);

            insertBalance(c, child, a30, 5);
            insertBalance(c, other, a30, 7);
            insertBalance(c, nonAcc, a30, 3);
            insertBalance(c, parent, a31, 1);

            UUID[] actor = insertActor(c, salt);
            UUID batch = insertIqcBatch(c, actor[0], actor[1], salt, child, a31, unit);
            insertPreference(c, child, a31, "B01-3-4", batch, actor);
            insertPreference(c, child, prefOnly, "C02-1-1", batch, actor);
            return new Fixture(parent, child, other, nonAcc, a30, a31, residue, disabled, noPlace, deleted, prefOnly);
        }
    }

    private static UUID insertWarehouse(Connection c, String code, UUID parentId, boolean accountable) throws Exception {
        UUID id = UUID.randomUUID();
        try (PreparedStatement ps = c.prepareStatement(
                "INSERT INTO warehouses(id, code, name, parent_id, is_accountable) VALUES (?, ?, ?, ?, ?)")) {
            ps.setObject(1, id);
            ps.setString(2, code);
            ps.setString(3, "货架清单测试仓 " + code);
            ps.setObject(4, parentId);
            ps.setBoolean(5, accountable);
            ps.executeUpdate();
        }
        return id;
    }

    private static UUID insertUnit(Connection c, String name) throws Exception {
        UUID id = UUID.randomUUID();
        try (PreparedStatement ps = c.prepareStatement(
                "INSERT INTO units(id, code, name, status) VALUES (?, ?, ?, '使用')")) {
            ps.setObject(1, id);
            ps.setString(2, "U-" + name);
            ps.setString(3, "个");
            ps.executeUpdate();
        }
        return id;
    }

    private static UUID insertGoods(Connection c, String code, String place, String status,
                                    boolean deleted, UUID unitId) throws Exception {
        UUID id = UUID.randomUUID();
        try (PreparedStatement ps = c.prepareStatement(
                "INSERT INTO goods(id, code, name, series, stock_place, status, is_deleted, unit_id, code_sequence) "
                        + "VALUES (?, ?, ?, 'YF-60', ?, ?, ?, ?, "
                        + "(SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods))")) {
            ps.setObject(1, id);
            ps.setString(2, code);
            ps.setString(3, "货架清单测试货品 " + code);
            ps.setString(4, place);
            ps.setString(5, status);
            ps.setBoolean(6, deleted);
            ps.setObject(7, unitId);
            ps.executeUpdate();
        }
        return id;
    }

    private static void insertBalance(Connection c, UUID warehouseId, UUID goodsId, double qty) throws Exception {
        try (PreparedStatement ps = c.prepareStatement(
                "INSERT INTO stock_balances(warehouse_id, goods_id, qty) VALUES (?, ?, ?)")) {
            ps.setObject(1, warehouseId);
            ps.setObject(2, goodsId);
            ps.setDouble(3, qty);
            ps.executeUpdate();
        }
    }

    /** 返回 [userId, employeeId]（偏好表 last_selected_by/created_by/updated_by 非空 FK）。 */
    private static UUID[] insertActor(Connection c, String salt) throws Exception {
        UUID employeeId = UUID.randomUUID();
        UUID userId = UUID.randomUUID();
        try (PreparedStatement ps = c.prepareStatement(
                "INSERT INTO employees(id, code, full_name, id_type, department_id, hire_date, status, employment_type) "
                        + "VALUES (?, ?, ?, '其他', (SELECT id FROM departments ORDER BY code LIMIT 1), "
                        + "DATE '2026-01-01', 'active', 'regular')")) {
            ps.setObject(1, employeeId);
            ps.setString(2, "EMP-SHELF-" + salt);
            ps.setString(3, "货架清单测试员工-" + salt);
            ps.executeUpdate();
        }
        try (PreparedStatement ps = c.prepareStatement(
                "INSERT INTO users(id, employee_id, login_account, password_hash, must_change_password, is_super_admin, status) "
                        + "VALUES (?, ?, ?, 'argon2-test-not-used', false, false, 'active')")) {
            ps.setObject(1, userId);
            ps.setObject(2, employeeId);
            ps.setString(3, "shelf-" + salt);
            ps.executeUpdate();
        }
        return new UUID[] {userId, employeeId};
    }

    private static UUID insertIqcBatch(Connection c, UUID userId, UUID employeeId, String salt,
                                       UUID warehouseId, UUID goodsId, UUID unitId) throws Exception {
        UUID id = UUID.randomUUID();
        // 批次与其明细必须落在同一个事务里：V446 的延迟约束触发器在提交时校验
        // 「confirmed_count == 明细行数」，自动提交模式下批次一插入就会先行触发。
        // 本用例验证的是货架清单查询，只需要一个可被库位偏好引用的合法批次身份；
        // IQC 放行的金额/重量守恒链路由 IQC 自己的用例覆盖，这里临时关闭用户触发器
        //（session_replication_role=replica，仅本连接本段），CHECK 约束仍然生效。
        boolean previousAutoCommit = c.getAutoCommit();
        c.setAutoCommit(false);
        try (Statement guards = c.createStatement()) {
            guards.execute("SET session_replication_role = replica");
        try (PreparedStatement batch = c.prepareStatement(
                    "INSERT INTO procurement_iqc_stock_in_batches(id, actor_user_id, actor_employee_id, receipt_type, "
                            + "receipt_id, idempotency_key, request_hash, confirmed_count) "
                            // confirmed_count 必须 > 0（CHECK）且等于本批 item 行数
                            //（V446 延迟约束触发器 trg_validate_procurement_iqc_stock_in_batch_count）：
                            // 两者夹住，夹具必须真造一行 item（2026-09-11）。
                            + "VALUES (?, ?, ?, 'PURCHASE', ?, ?, ?, 1)")) {
                batch.setObject(1, id);
                batch.setObject(2, userId);
                batch.setObject(3, employeeId);
                batch.setObject(4, UUID.randomUUID());
                batch.setString(5, "shelf-test:" + salt);
                batch.setString(6, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
                batch.executeUpdate();
            }
            insertIqcBatchItem(c, id, warehouseId, goodsId, unitId, employeeId);
            guards.execute("SET session_replication_role = origin");
            c.commit();
        } catch (Exception failure) {
            c.rollback();
            throw failure;
        } finally {
            try (Statement reset = c.createStatement()) {
                reset.execute("SET session_replication_role = origin");
            }
            c.setAutoCommit(previousAutoCommit);
        }
        return id;
    }

    /** 批次必须带一行明细：库位偏好只引用批次身份，但 V446 的守卫要求数量自洽。 */
    private static void insertIqcBatchItem(Connection c, UUID batchId, UUID warehouseId,
                                           UUID goodsId, UUID unitId, UUID actorEmployeeId) throws Exception {
        UUID inspectionItemId = UUID.randomUUID();
        try (PreparedStatement ps = c.prepareStatement(
                "INSERT INTO procurement_inspection_items(id, receipt_type, receipt_id, receipt_item_id, "
                        + "warehouse_id, goods_id, unit_id, unit_rate, received_base_qty) "
                        + "VALUES (?, 'PURCHASE', ?, ?, ?, ?, ?, 1, 1)")) {
            ps.setObject(1, inspectionItemId);
            ps.setObject(2, UUID.randomUUID());
            ps.setObject(3, UUID.randomUUID());
            ps.setObject(4, warehouseId);
            ps.setObject(5, goodsId);
            ps.setObject(6, unitId);
            ps.executeUpdate();
        }
        UUID eventId = UUID.randomUUID();
        try (PreparedStatement ps = c.prepareStatement(
                // PASS 事件必须显式声明「需要仓库入库」（V446 守卫 fn_guard_procurement_iqc_stock_in_release_flag）。
                "INSERT INTO procurement_inspection_events(id, inspection_item_id, action, base_qty, reason, "
                        // requires_warehouse_stock_in=TRUE 的 PASS 事件必须带操作员工与放行金额
                        //（V446 procurement_inspection_events_stock_in_flag_chk）。
                        + "requires_warehouse_stock_in, actor_employee_id, released_amount_local) "
                        + "VALUES (?, ?, 'PASS', 1, '货架清单夹具', TRUE, ?, 0)")) {
            ps.setObject(1, eventId);
            ps.setObject(2, inspectionItemId);
            ps.setObject(3, actorEmployeeId);
            ps.executeUpdate();
        }
        UUID movementId = UUID.randomUUID();
        try (PreparedStatement ps = c.prepareStatement(
                "INSERT INTO stock_movements(id, transaction_date, movement_type, source_doc_type, "
                        + "source_doc_id, goods_id, warehouse_id, direction, qty) "
                        + "VALUES (?, now(), 1, 'PURCHASE_RECEIPT', ?, ?, ?, 1, 1)")) {
            ps.setObject(1, movementId);
            ps.setObject(2, UUID.randomUUID());
            ps.setObject(3, goodsId);
            ps.setObject(4, warehouseId);
            ps.executeUpdate();
        }
        try (PreparedStatement ps = c.prepareStatement(
                "INSERT INTO procurement_iqc_stock_in_batch_items(id, batch_id, position, inspection_item_id, "
                        + "pass_event_id, stock_movement_id, warehouse_id, goods_id, "
                        + "expected_remaining_base_qty, base_qty, amount_local, place_snapshot) "
                        + "VALUES (?, ?, 1, ?, ?, ?, ?, ?, 1, 1, 0, 'A31-1-1')")) {
            ps.setObject(1, UUID.randomUUID());
            ps.setObject(2, batchId);
            ps.setObject(3, inspectionItemId);
            ps.setObject(4, eventId);
            ps.setObject(5, movementId);
            ps.setObject(6, warehouseId);
            ps.setObject(7, goodsId);
            ps.executeUpdate();
        }
    }

    private static void insertPreference(Connection c, UUID warehouseId, UUID goodsId, String place,
                                         UUID iqcBatchId, UUID[] actor) throws Exception {
        try (PreparedStatement ps = c.prepareStatement(
                "INSERT INTO warehouse_goods_place_preferences(warehouse_id, goods_id, place, source_kind, "
                        + "source_iqc_batch_id, source_registered_at, last_selected_by, created_by, updated_by) "
                        + "VALUES (?, ?, ?, 'IQC_STOCK_IN', ?, now(), ?, ?, ?)")) {
            ps.setObject(1, warehouseId);
            ps.setObject(2, goodsId);
            ps.setString(3, place);
            ps.setObject(4, iqcBatchId);
            ps.setObject(5, actor[1]);
            ps.setObject(6, actor[0]);
            ps.setObject(7, actor[0]);
            ps.executeUpdate();
        }
    }

    /** 命名参数 SQL → JDBC 位置参数（按出现顺序绑定，同名可重复出现）。 */
    private static List<Map<String, Object>> query(Connection c, String namedSql, Map<String, Object> params)
            throws Exception {
        List<String> order = new ArrayList<>();
        Matcher m = NAMED_PARAM.matcher(namedSql);
        StringBuilder sql = new StringBuilder();
        while (m.find()) {
            order.add(m.group(1));
            m.appendReplacement(sql, "?");
        }
        m.appendTail(sql);
        for (String name : order) {
            assertTrue(params.containsKey(name), "缺少命名参数绑定：" + name);
        }
        List<Map<String, Object>> out = new ArrayList<>();
        try (PreparedStatement ps = c.prepareStatement(sql.toString())) {
            for (int i = 0; i < order.size(); i++) {
                ps.setObject(i + 1, params.get(order.get(i)));
            }
            try (ResultSet rs = ps.executeQuery()) {
                int cols = rs.getMetaData().getColumnCount();
                while (rs.next()) {
                    Map<String, Object> row = new LinkedHashMap<>();
                    for (int i = 1; i <= cols; i++) {
                        row.put(rs.getMetaData().getColumnLabel(i), rs.getObject(i));
                    }
                    out.add(row);
                }
            }
        }
        return out;
    }

    private static Map<String, Object> rowOf(List<Map<String, Object>> rows, UUID goodsId) {
        return rows.stream().filter(r -> goodsId.equals(r.get("goods_id"))).findFirst()
                .orElseThrow(() -> new AssertionError("结果集缺少货品 " + goodsId));
    }

    private static int indexOf(List<Map<String, Object>> rows, UUID goodsId) {
        for (int i = 0; i < rows.size(); i++) {
            if (goodsId.equals(rows.get(i).get("goods_id"))) return i;
        }
        return -1;
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }
}
