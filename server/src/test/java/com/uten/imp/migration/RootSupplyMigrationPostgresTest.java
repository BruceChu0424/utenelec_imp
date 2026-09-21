package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.io.IOException;
import java.io.InputStream;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Independent database conservation checks for externally supplied root products.
 *
 * <p>同类还锁了 V598「货品来源按最近一次确认路线回填」的两条取数口径 (停用节点仍算数、
 * 确认时刻并列取最新一条)：那两条用例原本是按历史分析推导的 /last-routes 记忆查询的回归，
 * 2026-09-16 供应方式收口成货品主档单一事实源后，同一口径的落点从查询结果变成 goods.source_type。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class RootSupplyMigrationPostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine");
    private static final UUID UNIT = UUID.randomUUID();
    private static final UUID SALES_UNIT = UUID.randomUUID();
    private static final UUID WAREHOUSE = UUID.randomUUID();
    private static final UUID GOODS = UUID.randomUUID();
    private static final java.util.concurrent.atomic.AtomicInteger ORDER_SEQUENCE =
            new java.util.concurrent.atomic.AtomicInteger(700000);
    private static UUID actor;
    private static UUID employee;
    private static UUID historicalItem;
    private static JdbcTemplate jdbc;
    private static TransactionTemplate transaction;
    private static Fixture legacyRoot;
    private static UUID legacyReservation;
    private static UUID legacyOutput;
    private static List<String> rootStateBeforeV479;
    private static List<Map<String, Object>> appliedHistoryBeforeV479;
    private static String zeroMaterialFunctionBeforeV479;

    @BeforeAll
    static void migrateHistoricalSource() {
        POSTGRES.start();
        migrate("477");
        var dataSource = new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        jdbc = new JdbcTemplate(dataSource);
        transaction = new TransactionTemplate(new DataSourceTransactionManager(dataSource));
        employee = jdbc.queryForObject("SELECT id FROM employees ORDER BY id LIMIT 1", UUID.class);
        actor = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO users(id, employee_id, login_account, password_hash, status)
                VALUES (?, ?, ?, 'test-only-hash', 'active')
                """, actor, employee, "root-output-" + actor);
        jdbc.update("INSERT INTO units(id, code, name) VALUES (?, ?, 'piece'), (?, ?, 'box')",
                UNIT, "ROOT-U-" + UNIT, SALES_UNIT, "ROOT-U-" + SALES_UNIT);
        jdbc.update("""
                INSERT INTO warehouses(id, code, name, status, is_accountable)
                VALUES (?, ?, 'Root output warehouse', '使用', TRUE)
                """, WAREHOUSE, "ROOT-W-" + WAREHOUSE);
        jdbc.update("""
                INSERT INTO goods(id, code, name, unit_id, code_sequence, source_type)
                VALUES (?, ?, 'Root output goods', ?,
                    (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods), '采购')
                """, GOODS, "ROOT-G-" + GOODS, UNIT);
        UUID analysisId = insertAnalysis();
        historicalItem = UUID.randomUUID();
        insertManualSource(historicalItem, analysisId, bd("10"));
        migrate("478");
        assertThat(jdbc.queryForObject("""
                SELECT checksum FROM flyway_schema_history WHERE version = '478' AND success
                """, Integer.class)).isEqualTo(1310089889);
        legacyRoot = root(true, "3", "10");
        legacyReservation = reserve(legacyRoot, "1");
        legacyOutput = fulfill(legacyRoot, "1", legacyReservation);
        assertFulfilled(legacyRoot, "0.3333");
        rootStateBeforeV479 = rootUpgradeState();
        appliedHistoryBeforeV479 = migrationHistoryThroughV478();
        zeroMaterialFunctionBeforeV479 = zeroMaterialFunction();
        migrate("479");
        flyway("479").validate();
    }

    private static void migrate(String target) {
        flyway(target).migrate();
    }

    private static Flyway flyway(String target) {
        return Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").target(target).load();
    }

    private static List<Map<String, Object>> migrationHistoryThroughV478() {
        return jdbc.queryForList("""
                SELECT installed_rank, version, description, type, script, checksum,
                    installed_by, installed_on, execution_time, success
                FROM flyway_schema_history WHERE version::integer <= 478
                ORDER BY installed_rank
                """);
    }

    private static String zeroMaterialFunction() {
        return jdbc.queryForObject("""
                SELECT pg_get_functiondef('fn_guard_execution_segment_requirement_shape()'::regprocedure)
                """, String.class);
    }

    private static List<String> rootUpgradeState() {
        return List.of(
                jdbc.queryForObject("""
                        SELECT row_to_json(snapshot_row)::text FROM production_material_analyses snapshot_row WHERE id = ?
                        """, String.class, legacyRoot.analysisId()),
                jdbc.queryForObject("""
                        SELECT row_to_json(snapshot_row)::text FROM production_material_analysis_items snapshot_row WHERE id = ?
                        """, String.class, legacyRoot.itemId()),
                jdbc.queryForObject("""
                        SELECT row_to_json(snapshot_row)::text FROM production_material_analysis_materials snapshot_row WHERE id = ?
                        """, String.class, legacyRoot.materialId()),
                jdbc.queryForObject("""
                        SELECT row_to_json(snapshot_row)::text FROM stock_reservations snapshot_row WHERE id = ?
                        """, String.class, legacyReservation),
                jdbc.queryForObject("""
                        SELECT row_to_json(snapshot_row)::text FROM preplan_root_output_events snapshot_row WHERE id = ?
                        """, String.class, legacyOutput),
                jdbc.queryForObject("""
                        SELECT row_to_json(snapshot_row)::text FROM sales_order_items snapshot_row WHERE id = ?
                        """, String.class, legacyRoot.salesItemId()));
    }

    @Test
    void appliedV478UpgradesNonemptyToV479WithoutRewritingHistoryOrRootFacts() {
        assertThat(migrationHistoryThroughV478()).containsExactlyElementsOf(appliedHistoryBeforeV479);
        assertThat(rootUpgradeState()).containsExactlyElementsOf(rootStateBeforeV479);
        assertFulfilled(legacyRoot, "0.3333");
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM flyway_schema_history WHERE version = '479' AND success
                """, Long.class)).isEqualTo(1L);
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM flyway_schema_history WHERE success
                """, Long.class)).isEqualTo(441L);
        flyway("479").validate();
        assertThat(flyway("479").migrate().migrationsExecuted).isZero();
        assertThat(migrationHistoryThroughV478()).containsExactlyElementsOf(appliedHistoryBeforeV479);
    }

    @Test
    void v479ChangesOnlyTheManufacturingBomAbsencePredicate() {
        String oldPredicate = "AND material.active = TRUE";
        assertThat(zeroMaterialFunctionBeforeV479)
                .contains(oldPredicate)
                .doesNotContain("material.node_role");
        assertThat(zeroMaterialFunction()).isEqualTo(zeroMaterialFunctionBeforeV479.replace(
                oldPredicate, oldPredicate + " AND material.node_role = 'BOM_COMPONENT'"));
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void existingSourcesRemainUnfulfilledWithoutInventingRootNodes() {
        var row = jdbc.queryForMap("""
                SELECT requested_qty, root_material_id, root_fulfilled_qty
                FROM production_material_analysis_items WHERE id = ?
                """, historicalItem);
        assertThat(row.get("root_material_id")).isNull();
        assertThat((BigDecimal) row.get("root_fulfilled_qty")).isEqualByComparingTo("0");
        assertThat((BigDecimal) row.get("requested_qty")).isEqualByComparingTo("10");
    }

    @Test
    void rootRoleAndSourceIdentityRemainExplicit() {
        Fixture root = root(true, "1", "10");
        assertThatThrownBy(() -> jdbc.update("""
                UPDATE production_material_analysis_materials SET depth = 1 WHERE id = ?
                """, root.materialId())).satisfies(RootSupplyMigrationPostgresTest::checkViolation);
        assertThatThrownBy(() -> jdbc.update("""
                UPDATE production_material_analysis_materials SET parent_node_key = 'wrong-parent' WHERE id = ?
                """, root.materialId())).satisfies(RootSupplyMigrationPostgresTest::checkViolation);
        Fixture other = root(false, "1", "10");
        UUID reservation = reserve(root, "1");
        assertThatThrownBy(() -> insertEvent(root, "FULFILL", null, "1", reservation,
                other.materialId(), UUID.randomUUID()))
                .satisfies(RootSupplyMigrationPostgresTest::checkViolation);
    }

    @Test
    void salesOutputEventsReverseExactlyAndCannotBeRewritten() {
        Fixture root = root(true, "1", "10");
        UUID firstReservation = reserve(root, "2");
        UUID first = fulfill(root, "2", firstReservation);
        fulfill(root, "3", reserve(root, "3"));
        assertFulfilled(root, "5");
        transaction.executeWithoutResult(status -> {
            jdbc.update("UPDATE stock_reservations SET released_qty = qty, status = 1 WHERE id = ?",
                    firstReservation);
            reverse(root, first, "2", firstReservation);
        });
        assertFulfilled(root, "3");
        assertThatThrownBy(() -> reverse(root, first, "2", firstReservation))
                .satisfies(RootSupplyMigrationPostgresTest::integrityViolation);
        assertThatThrownBy(() -> jdbc.update(
                "UPDATE preplan_root_output_events SET qty_base = 9 WHERE id = ?", first))
                .satisfies(RootSupplyMigrationPostgresTest::checkViolation);
        assertThatThrownBy(() -> jdbc.update("DELETE FROM preplan_root_output_events WHERE id = ?", first))
                .satisfies(RootSupplyMigrationPostgresTest::checkViolation);
        assertThatThrownBy(() -> jdbc.update("""
                UPDATE production_material_analysis_items SET root_fulfilled_qty = 7 WHERE id = ?
                """, root.itemId())).satisfies(RootSupplyMigrationPostgresTest::checkViolation);
        assertFulfilled(root, "3");
    }

    @Test
    void cumulativeBaseQuantityAvoidsPerReceiptUnitConversionDrift() {
        Fixture root = root(true, "3", "10");
        UUID reservation = reserve(root, "1");
        UUID first = fulfill(root, "1", reservation);
        assertFulfilled(root, "0.3333");
        fulfill(root, "1", reserve(root, "1"));
        assertFulfilled(root, "0.6666");
        fulfill(root, "1", reserve(root, "1"));
        assertFulfilled(root, "1.0000");
        transaction.executeWithoutResult(status -> {
            jdbc.update("""
                    UPDATE stock_reservations SET released_qty = qty, status = 1 WHERE id = ?
                    """, reservation);
            reverse(root, first, "1", reservation);
        });
        assertFulfilled(root, "0.6666");
    }

    @Test
    void aSalesReservationCannotFulfillTheRootTwice() {
        Fixture root = root(true, "1", "10");
        UUID reservation = reserve(root, "1");
        fulfill(root, "1", reservation);
        assertThatThrownBy(() -> fulfill(root, "1", reservation))
                .satisfies(RootSupplyMigrationPostgresTest::integrityViolation);
        assertFulfilled(root, "1");
    }

    @Test
    void fulfilledBaseCannotExceedSourceDemandAndBeSilentlyCapped() {
        Fixture root = root(true, "1", "2");
        UUID reservation = reserve(root, "3");
        assertThatThrownBy(() -> fulfill(root, "3", reservation))
                .satisfies(RootSupplyMigrationPostgresTest::checkViolation);
        assertFulfilled(root, "0");
    }

    @Test
    void manualDemandCannotBeCompletedFromReusablePublicStockWithoutAnOrigin() {
        Fixture root = root(false, "1", "10");
        assertThatThrownBy(() -> fulfill(root, "1", null))
                .satisfies(RootSupplyMigrationPostgresTest::checkViolation);
        assertFulfilled(root, "0");
    }

    @Test
    void outputLedgerIsRegisteredInTheExistingResetPolicy() {
        String definition = jdbc.queryForObject(
                "SELECT pg_get_functiondef('business_data_reset()'::regprocedure)", String.class);
        assertThat(definition).contains("('preplan_root_output_events', 'CLEAR')");
    }

    /**
     * 2026-09-16 供应方式收口成货品主档单一事实源：按历史分析推导的 /last-routes
     * 记忆整套退役，存量确认由 V598 一次性种进 goods.source_type。
     *
     * <p>这条守的是旧记忆查询当年就定下的口径——**停用节点 (active = FALSE) 上
     * 的确认仍然算数**：那次确认是人做的，不能因为节点后来被 BOM 刷新掉就丢掉
     * 用户选过的供应方式。重放一次零行，回填幂等。
     */
    @Test
    void inactiveConfirmedNodesStillSeedTheGoodsMasterSourceType() {
        UUID goods = historyGoods();
        historyMaterial(goods, "SUBCONTRACT", false, "2026-09-05T10:00:00Z");

        backfillGoodsSourceTypeFromRouteHistory();

        assertThat(goodsSourceType(goods)).isEqualTo("委外");
        backfillGoodsSourceTypeFromRouteHistory();
        assertThat(goodsSourceType(goods)).isEqualTo("委外");
    }

    /**
     * 同一货品在多份分析里确认过不同路线时，主档只认**最近一次**确认：并列到同一
     * 确认时刻的按建行时间兜底取最新，更早的确认一律不写进主档。
     *
     * <p>口径变更留痕：旧 /last-routes 在这种并列上拒绝给默认值 (宁可留空也不猜)，
     * 主档是单值列没有「留空」这个选项，所以 V598 按稳定排序取最新一条；但绝不
     * 倒退回更早的那次确认。
     */
    @Test
    void conflictingRoutesAtTheSameLatestConfirmationTakeTheNewestRowOnly() {
        UUID goods = historyGoods();
        historyMaterial(goods, "BUY", false, "2026-09-04T10:00:00Z");
        historyMaterial(goods, "MAKE", false, "2026-09-05T10:00:00Z", "2026-09-05T09:00:00Z");
        historyMaterial(goods, "SUBCONTRACT", true, "2026-09-05T10:00:00Z", "2026-09-05T09:30:00Z");

        backfillGoodsSourceTypeFromRouteHistory();

        assertThat(goodsSourceType(goods))
                .as("并列时刻取建行更晚的 SUBCONTRACT；并列里较早的 MAKE 与更早的 BUY 都不得写进主档")
                .isEqualTo("委外")
                .isNotEqualTo("自制")
                .isNotEqualTo("采购");
    }

    /**
     * 直接执行 V598 脚本原文而不是在测试里复写一遍 SQL：本类的库停在 V479，
     * 回填口径一旦改了这两条断言就跟着红。脚本只有一条 UPDATE，它依赖的表与列
     * 在 V479 时点全部存在，不写 flyway_schema_history、不影响本类的 V478/V479 断言。
     */
    private static void backfillGoodsSourceTypeFromRouteHistory() {
        jdbc.execute(readMigration("V598__goods_source_type_backfill_from_route_history.sql"));
    }

    private static String readMigration(String fileName) {
        try (InputStream script = RootSupplyMigrationPostgresTest.class
                .getResourceAsStream("/db/migration/" + fileName)) {
            assertThat(script).as("迁移脚本必须在测试 classpath 上: %s", fileName).isNotNull();
            return new String(script.readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException failure) {
            throw new IllegalStateException("无法读取迁移脚本 " + fileName, failure);
        }
    }

    private static String goodsSourceType(UUID goods) {
        return jdbc.queryForObject("SELECT source_type FROM goods WHERE id = ?", String.class, goods);
    }

    private static UUID historyGoods() {
        UUID goods = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO goods(id, code, name, unit_id, code_sequence)
                VALUES (?, ?, 'Historical route material', ?,
                    (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods))
                """, goods, "ROOT-HISTORY-" + goods, UNIT);
        return goods;
    }

    private static void historyMaterial(UUID goods, String route, boolean active, String confirmedAt) {
        historyMaterial(goods, route, active, confirmedAt, confirmedAt);
    }

    /**
     * [createdAt] 显式给值而不是靠 DEFAULT now()：V598 在「确认时刻并列」时按建行
     * 时间兜底排序，用真实时钟播种会让并列用例的胜出方随机。
     */
    private static void historyMaterial(
            UUID goods, String route, boolean active, String confirmedAt, String createdAt) {
        UUID analysis = insertAnalysis();
        UUID item = UUID.randomUUID();
        insertManualSource(item, analysis, bd("1"));
        UUID material = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO production_material_analysis_materials(id, analysis_id, analysis_item_id,
                    node_key, goods_id, unit_id, depth, path, per_product_qty,
                    required_qty, available_qty, allocated_available_qty, shortage_qty,
                    source_suggestion, confirmed_route, route_reason, route_confirmed_by,
                    route_confirmed_at, active, created_at, created_by, updated_by)
                VALUES (?, ?, ?, ?, ?, ?, 1, ?, 1, 1, 0, 0, 1,
                    'BUY', ?, NULL, ?, CAST(? AS timestamptz), ?, CAST(? AS timestamptz), ?, ?)
                """, material, analysis, item, "HISTORY-" + material, goods, UNIT,
                "HISTORY-" + material, route, actor, confirmedAt, active, createdAt, actor, actor);
    }

    private static Fixture root(boolean sales, String rate, String requested) {
        return transaction.execute(status -> {
            UUID analysisId = insertAnalysis();
            UUID itemId = UUID.randomUUID();
            UUID salesItemId = sales ? insertSalesItem(rate, requested) : null;
            if (sales) {
                jdbc.update("""
                        INSERT INTO production_material_analysis_items(id, analysis_id, source_type,
                            sales_order_item_id, goods_id, unit_id, requested_qty, line_priority,
                            created_by, updated_by)
                        VALUES (?, ?, 'SALES_ORDER_ITEM', ?, ?, ?, ?, 1, ?, ?)
                        """, itemId, analysisId, salesItemId, GOODS,
                        bd(rate).compareTo(BigDecimal.ONE) == 0 ? UNIT : SALES_UNIT,
                        bd(requested), actor, actor);
            } else {
                insertManualSource(itemId, analysisId, bd(requested));
            }
            UUID materialId = UUID.randomUUID();
            BigDecimal required = bd(rate).multiply(bd(requested));
            jdbc.update("""
                    INSERT INTO production_material_analysis_materials(id, analysis_id, analysis_item_id,
                        node_key, node_role, goods_id, unit_id, depth, path, per_product_qty,
                        required_qty, available_qty, allocated_available_qty, shortage_qty,
                        source_suggestion, confirmed_route, route_reason, route_confirmed_by,
                        route_confirmed_at, created_by, updated_by)
                    VALUES (?, ?, ?, ?, 'ROOT_SUPPLY', ?, ?, 0, ?, ?, ?, 0, 0, ?,
                        'MAKE', 'BUY', NULL, ?, now(), ?, ?)
                    """, materialId, analysisId, itemId, "ROOT-" + itemId, GOODS, UNIT,
                    "ROOT-" + itemId, bd(rate), required, required, actor, actor, actor);
            jdbc.update("UPDATE production_material_analysis_items SET root_material_id = ? WHERE id = ?",
                    materialId, itemId);
            return new Fixture(analysisId, itemId, materialId, salesItemId);
        });
    }

    private static UUID insertAnalysis() {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO production_material_analyses(id, warehouse_id, status, fingerprint,
                    initial_idempotency_key, maker_id, created_by, updated_by)
                VALUES (?, ?, 'ACTIVE', ?, ?, ?, ?, ?)
                """, id, WAREHOUSE, "a".repeat(64), "root-output-" + id, employee, actor, actor);
        return id;
    }

    private static void insertManualSource(UUID itemId, UUID analysisId, BigDecimal requested) {
        jdbc.update("""
                INSERT INTO production_material_analysis_items(id, analysis_id, source_type, goods_id,
                    unit_id, source_ref, source_reason, requested_qty, line_priority, created_by, updated_by)
                VALUES (?, ?, 'OTHER', ?, ?, ?, 'Root output regression', ?, 1, ?, ?)
                """, itemId, analysisId, GOODS, UNIT, "ROOT-SOURCE-" + itemId, requested, actor, actor);
    }

    private static UUID insertSalesItem(String rate, String requested) {
        UUID clientId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();
        String billNo = "XD" + jdbc.queryForObject(
                "SELECT to_char(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai', 'YYYYMMDD')", String.class)
                + "%06d".formatted(ORDER_SEQUENCE.incrementAndGet());
        jdbc.update("""
                -- 彩排停在 V479：clients.sales_payment_type 仍在且在线客户必填(V443 CHECK)，V630 才整列退役。
                INSERT INTO clients(id, code, name, code_sequence, sales_payment_type)
                VALUES (?, ?, 'Root supply client',
                    (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM clients), 'MONTHLY')
                """, clientId, "ROOT-KH-" + clientId);
        jdbc.update("""
                INSERT INTO sales_orders(id, bill_no, bill_date, client_id, status, finance_confirmed)
                VALUES (?, ?, CURRENT_DATE, ?, 1, TRUE)
                """, orderId, billNo, clientId);
        jdbc.update("""
                INSERT INTO sales_order_items(id, bill_no, bill_date, order_id, goods_id,
                    unit_id, unit_rate, qty, goods_code_snapshot, goods_name_snapshot,
                    goods_snapshot_source, goods_snapshot_locked_at)
                VALUES (?, ?, CURRENT_DATE, ?, ?, ?, ?, ?, 'ROOT-GOODS', 'Root output goods',
                    'MASTER_AT_APPROVAL', now())
                """, itemId, billNo, orderId, GOODS,
                bd(rate).compareTo(BigDecimal.ONE) == 0 ? UNIT : SALES_UNIT, bd(rate), bd(requested));
        return itemId;
    }

    private static UUID reserve(Fixture root, String qty) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO stock_reservations(id, order_item_id, goods_id, warehouse_id, qty,
                    consumed_qty, released_qty, status, source, source_doc_type, source_doc_id)
                VALUES (?, ?, ?, ?, ?, 0, 0, 0, 0, 'ROOT_SUPPLY_INBOUND', ?)
                """, id, root.salesItemId(), GOODS, WAREHOUSE, bd(qty), root.itemId());
        return id;
    }

    private static UUID fulfill(Fixture root, String qty, UUID reservation) {
        UUID id = UUID.randomUUID();
        insertEvent(root, "FULFILL", null, qty, reservation, root.materialId(), id);
        return id;
    }

    private static void reverse(Fixture root, UUID original, String qty, UUID reservation) {
        insertEvent(root, "REVERSE", original, qty, reservation, root.materialId(), UUID.randomUUID());
    }

    private static void insertEvent(Fixture root, String kind, UUID original, String qty,
            UUID reservation, UUID materialId, UUID id) {
        jdbc.update("""
                INSERT INTO preplan_root_output_events(id, analysis_id, analysis_item_id, root_material_id,
                    event_kind, reversed_event_id, warehouse_id, goods_id, qty_base,
                    sales_order_item_id, sales_reservation_id, idempotency_key, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, id, root.analysisId(), root.itemId(), materialId, kind, original,
                WAREHOUSE, GOODS, bd(qty), root.salesItemId(), reservation, "root-output-event-" + id, actor);
    }

    private static void assertFulfilled(Fixture root, String expected) {
        assertThat(jdbc.queryForObject("""
                SELECT root_fulfilled_qty FROM production_material_analysis_items WHERE id = ?
                """, BigDecimal.class, root.itemId())).isEqualByComparingTo(expected);
    }

    private static void checkViolation(Throwable error) {
        assertThat(sqlState(error)).isEqualTo("23514");
    }

    private static void integrityViolation(Throwable error) {
        assertThat(sqlState(error)).isIn("23514", "23505");
    }

    private static String sqlState(Throwable error) {
        Throwable root = error;
        while (root.getCause() != null) root = root.getCause();
        assertThat(root).isInstanceOf(PSQLException.class);
        return ((PSQLException) root).getSQLState();
    }

    private static BigDecimal bd(String value) { return new BigDecimal(value); }
    private record Fixture(UUID analysisId, UUID itemId, UUID materialId, UUID salesItemId) {}
}
