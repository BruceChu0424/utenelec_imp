package com.uten.imp.features.stock;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Types;
import java.time.Duration;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.assertTimeoutPreemptively;

/**
 * V178 焦点数据正确性验证（PostgreSQL 集成测试，testcontainers + 全量 Flyway 迁移，原生 JDBC）。
 *
 * <p>覆盖 V178 的两个核心数据口径：
 * <ol>
 *   <li><b>缺口 C · 安全库存进销售 ATP</b>：镜像 {@code StockReservationRepository.globalAvailableBase}
 *       的原生 SQL（每个有货仓分别扣 goods.min_qty + GREATEST 钳位），
 *       验证全局承诺与仓库可拣口径一致。
 *   <li><b>缺口 B · 让单(yield) chain_status 回退</b>：用 {@code SalesOrderService.yieldReservation}
 *       同一个 {@code SalesOrderChainSql.chainStatusCaseSql}（V545 统一派生）拼出回退 UPDATE，
 *       验证 reserved_qty 回减与行状态机回退（7→1→2）。
 * </ol>
 *
 * <p>不启 Spring，只验 SQL 语义；与 {@link StockReservationSalesCompatibilityPostgresTest} 同款骨架
 * （PostgreSQL 16-alpine + Flyway 全量 migrate）。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SalesReservationSafetyStockPostgresTest {

    private static final java.util.concurrent.atomic.AtomicInteger CLIENT_CODE_SEQUENCE =
            new java.util.concurrent.atomic.AtomicInteger(920_000);

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @BeforeAll
    static void migrate() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    // ====================================================================
    // 测试 1：globalAvailableBase 扣安全库存 + GREATEST 钳位
    // ====================================================================
    @Test
    void globalAvailableBaseSubtractsSafetyStockAndClampsToZero() {
        assertTimeoutPreemptively(Duration.ofSeconds(20), () -> {
            try (Connection connection = connection()) {
                // 场景 a：min_qty=100（安全库存 100），余额 150，无预留 → 可用 = max(150-0-100,0) = 50
                UUID goodsA = UUID.randomUUID();
                UUID warehouseA = UUID.randomUUID();
                insertGoods(connection, goodsA, "GOODS-A-" + goodsA, 100.0);
                insertWarehouse(connection, warehouseA, "WH-A-" + warehouseA);
                insertBalance(connection, warehouseA, goodsA, 150.0);
                assertAvailable(connection, goodsA, null, 50.0, "安全库存 100 扣后应剩 50");

                // 场景 b：同 goodsA 插一笔生效预留（qty=60，warehouse_id=warehouseA）→ 可用 = max(150-60-100,0) = 0
                UUID reservationId = UUID.randomUUID();
                // order_item_id 是跨模块逻辑 FK（不建约束），可直接插任意 UUID；
                // V150 触发器会据 order_item_id 自动填 owner_type/owner_id/purpose。
                insertSalesReservation(connection, reservationId, UUID.randomUUID(),
                        goodsA, warehouseA, 60.0);
                assertAvailable(connection, goodsA, null, 0.0,
                        "预留 60 后 150-60-100=-10，GREATEST 钳位为 0");

                // 场景 c：min_qty=200 比余额 150 大（独立 goods/warehouse）→ 可用 = 0（保护安全库存不被吃）
                UUID goodsC = UUID.randomUUID();
                UUID warehouseC = UUID.randomUUID();
                insertGoods(connection, goodsC, "GOODS-C-" + goodsC, 200.0);
                insertWarehouse(connection, warehouseC, "WH-C-" + warehouseC);
                insertBalance(connection, warehouseC, goodsC, 150.0);
                assertAvailable(connection, goodsC, null, 0.0,
                        "min_qty(200)>余额(150) 时安全库存全锁，可用必须为 0");

                // 场景 d：两仓各 50、每仓安全 10 → 可承诺 40+40=80，
                // 不能按旧口径只全局扣一次得到 90。
                UUID goodsD = UUID.randomUUID();
                UUID warehouseD1 = UUID.randomUUID();
                UUID warehouseD2 = UUID.randomUUID();
                insertGoods(connection, goodsD, "GOODS-D-" + goodsD, 10.0);
                insertWarehouse(connection, warehouseD1, "WH-D1-" + warehouseD1);
                insertWarehouse(connection, warehouseD2, "WH-D2-" + warehouseD2);
                insertBalance(connection, warehouseD1, goodsD, 50.0);
                insertBalance(connection, warehouseD2, goodsD, 50.0);
                assertAvailable(connection, goodsD, null, 80.0,
                        "两仓必须分别保护安全库存，硬承诺不得超过 80");
            }
        });
    }

    // ====================================================================
    // 测试 2：让单(yield)的 chain_status 回退 SQL 逻辑
    // ====================================================================
    @Test
    void yieldChainStatusFallbackRewindsReservationState() {
        assertTimeoutPreemptively(Duration.ofSeconds(20), () -> {
            try (Connection connection = connection()) {
                // ---- 造数：客户 + 货品（min_qty 不参与本测试，给 0）+ 已审销售订单 + 订单行 ----
                UUID client = UUID.randomUUID();
                insertClient(connection, client, "yield test client");

                UUID goods = UUID.randomUUID();
                insertGoods(connection, goods, "GOODS-YIELD-" + goods, 0.0);

                UUID orderId = UUID.randomUUID();
                insertSalesOrder(
                        connection,
                        orderId,
                        "XD20260801000001",
                        client,
                        1);

                // 行数据：reserved=10, qty=20, shipped=0, returned=0, flag=0, planned=0, produced=0,
                // chain_status=7（可发货）。outstanding = qty-shipped+returned-flag = 20。
                UUID itemId = UUID.randomUUID();
                insertSalesOrderItem(connection, itemId, orderId, goods,
                        /*qty*/ 20.0, /*reserved*/ 10.0, /*shipped*/ 0.0,
                        /*returned*/ 0.0, /*flag*/ 0.0, /*planned*/ 0.0, /*produced*/ 0.0,
                        /*chainStatus*/ (short) 7, /*priority*/ (short) 3);

                // ---- 让单 :q=4 ----
                // SET 阶段用 OLD reserved(10)：reserved→10-4=6；统一 CASE（V545）：
                //   未交付 20>0；6 >= 20 ? 否；已发 0；未排 20-6-0=14>0 且 6>0 → chain=1（部分预留）
                int updated = executeYieldUpdate(connection, itemId, BigDecimal.valueOf(4));
                assertEquals(1, updated, "reserved(10)>=4，应更新 1 行");
                assertItem(connection, itemId, 6.0, (short) 1,
                        "让单 4：reserved 10→6(< outstanding 20)，chain 7→1 部分预留");

                // ---- 让单剩余 :q=6 ----
                // 此时 OLD reserved=6, chain=1(>0 进 CASE)：reserved→6-6=0；统一 CASE：
                //   0 >= 20 ? 否；已发 0；未排 20>0 且预留 0 → chain=2（待排产）
                updated = executeYieldUpdate(connection, itemId, BigDecimal.valueOf(6));
                assertEquals(1, updated, "reserved(6)>=6，应更新 1 行");
                assertItem(connection, itemId, 0.0, (short) 2,
                        "让单 6：reserved 6→0，chain 1→2 待排产");
            }
        });
    }

    // ============================ 查询/断言助手 ============================

    /**
     * 逐字镜像 {@link StockReservationRepository#globalAvailableBase} 的原生 SQL
     * （仅把 :gid/:cid 命名参数换为 JDBC 位置占位符；语义完全一致）。
     */
    private static BigDecimal globalAvailableBase(Connection c, UUID goodsId, UUID colorId) throws Exception {
        String sql = """
                SELECT GREATEST(
                  (SELECT COALESCE(SUM(GREATEST(
                              COALESCE(b.qty, 0)
                              - GREATEST(
                                  COALESCE(CAST(g.min_qty AS NUMERIC), 0), 0),
                              0)), 0)
                     FROM stock_balances b
                     JOIN goods g ON g.id = b.goods_id
                     WHERE b.goods_id = ?
                       AND (b.color_id IS NOT DISTINCT FROM CAST(? AS uuid)))
                  - (SELECT COALESCE(SUM(r.qty - r.consumed_qty - r.released_qty), 0)
                       FROM stock_reservations r
                       WHERE r.is_deleted = FALSE AND r.status = 0
                         AND r.goods_id = ?
                         AND (r.color_id IS NOT DISTINCT FROM CAST(? AS uuid)))
                , 0)
                """;
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            ps.setObject(1, goodsId);
            setNullableUuid(ps, 2, colorId);
            ps.setObject(3, goodsId);
            setNullableUuid(ps, 4, colorId);
            try (ResultSet rs = ps.executeQuery()) {
                assertTrue(rs.next());
                return rs.getBigDecimal(1);
            }
        }
    }

    private static void assertAvailable(Connection c, UUID goodsId, UUID colorId,
                                        double expected, String message) throws Exception {
        BigDecimal got = globalAvailableBase(c, goodsId, colorId);
        assertEquals(0, got.compareTo(BigDecimal.valueOf(expected)),
                message + "(实际=" + got.stripTrailingZeros().toPlainString() + ")");
    }

    /**
     * 与 {@code SalesOrderService.yieldReservation} 同一构造：预留增量 {@code - :q} 走
     * {@code SalesOrderChainSql.chainStatusCaseSql}（:q/:id → JDBC 位置占位符；最后两个 ? 为 id、q，
     * 其余全部是 q）。返回受影响行数（service 端断言 ==1）。
     */
    private static int executeYieldUpdate(Connection c, UUID itemId, BigDecimal q) throws Exception {
        String sql = "UPDATE sales_order_items\n"
                + "SET reserved_qty = COALESCE(reserved_qty,0) - ?,\n"
                + "    chain_status = "
                + com.uten.imp.common.saleschain.SalesOrderChainSql.chainStatusCaseSql(
                        com.uten.imp.common.saleschain.SalesOrderChainSql.ChainStatusInputs.of("")
                                .reservedDelta(" - ?"))
                + "\nWHERE id = ? AND COALESCE(reserved_qty,0) >= ?";
        int placeholders = (int) sql.chars().filter(ch -> ch == '?').count();
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            for (int i = 1; i <= placeholders - 2; i++) ps.setBigDecimal(i, q);
            ps.setObject(placeholders - 1, itemId);
            ps.setBigDecimal(placeholders, q);
            return ps.executeUpdate();
        }
    }

    private static void assertItem(Connection c, UUID itemId,
                                   double expectedReserved, short expectedChain,
                                   String message) throws Exception {
        try (PreparedStatement ps = c.prepareStatement(
                "SELECT reserved_qty, chain_status FROM sales_order_items WHERE id = ?")) {
            ps.setObject(1, itemId);
            try (ResultSet rs = ps.executeQuery()) {
                assertTrue(rs.next(), message);
                BigDecimal reserved = rs.getBigDecimal(1);
                short chain = rs.getShort(2);
                assertEquals(0, reserved.compareTo(BigDecimal.valueOf(expectedReserved)),
                        message + " → reserved_qty 期望 " + expectedReserved
                                + "，实际 " + reserved.stripTrailingZeros().toPlainString());
                assertEquals(expectedChain, chain,
                        message + " → chain_status 期望 " + expectedChain + "，实际 " + chain);
            }
        }
    }

    // ============================ 插入助手 ============================

    private static void insertGoods(Connection c, UUID id, String code, double minQty) throws Exception {
        try (PreparedStatement ps = c.prepareStatement(
                "INSERT INTO goods(id, code, name, min_qty, code_sequence) "
                        + "VALUES (?, ?, 'V178 safety-stock test goods', ?, "
                        + "(SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods))")) {
            ps.setObject(1, id);
            ps.setString(2, code);
            ps.setDouble(3, minQty);
            ps.executeUpdate();
        }
    }

    private static void insertWarehouse(Connection c, UUID id, String code) throws Exception {
        try (PreparedStatement ps = c.prepareStatement(
                "INSERT INTO warehouses(id, code, name) VALUES (?, ?, 'V178 safety-stock test warehouse')")) {
            ps.setObject(1, id);
            ps.setString(2, code);
            ps.executeUpdate();
        }
    }

    private static void insertBalance(Connection c, UUID warehouseId, UUID goodsId, double qty) throws Exception {
        // stock_balances：warehouse_id/goods_id NOT NULL，color_id 默认 NULL（NULLS NOT DISTINCT 唯一约束），
        // weight（V80 加列）可空。最小集 = (warehouse_id, goods_id, qty)。
        try (PreparedStatement ps = c.prepareStatement(
                "INSERT INTO stock_balances(warehouse_id, goods_id, qty) VALUES (?, ?, ?)")) {
            ps.setObject(1, warehouseId);
            ps.setObject(2, goodsId);
            ps.setDouble(3, qty);
            ps.executeUpdate();
        }
    }

    /**
     * 插一笔销售生效预留。order_item_id 为跨模块逻辑 FK（不建约束），可直接任意 UUID；
     * V150 触发器 trg_stock_reservation_owner_defaults 据 order_item_id 自动填
     * owner_type='SALES_ORDER_ITEM'/owner_id/purpose='SALES_FULFILLMENT'，故不必显式赋值。
     */
    private static void insertSalesReservation(Connection c, UUID id, UUID orderItemId,
                                               UUID goodsId, UUID warehouseId, double qty) throws Exception {
        try (PreparedStatement ps = c.prepareStatement("""
                INSERT INTO stock_reservations(
                    id, order_item_id, goods_id, warehouse_id,
                    qty, status, source, source_doc_type
                ) VALUES (?, ?, ?, ?, ?, 0, 0, 'SALES_ORDER')
                """)) {
            ps.setObject(1, id);
            ps.setObject(2, orderItemId);
            ps.setObject(3, goodsId);
            ps.setObject(4, warehouseId);
            ps.setDouble(5, qty);
            ps.executeUpdate();
        }
    }

    private static void insertClient(Connection c, UUID id, String name) throws Exception {
        int codeSequence = CLIENT_CODE_SEQUENCE.incrementAndGet();
        try (PreparedStatement ps = c.prepareStatement(
                "INSERT INTO clients(id, code, name, code_sequence, sales_payment_type) "
                        + "VALUES (?, ?, ?, ?, 'MONTHLY')")) {
            ps.setObject(1, id);
            ps.setString(2, "KH%06d".formatted(codeSequence));
            ps.setString(3, name);
            ps.setInt(4, codeSequence);
            ps.executeUpdate();
        }
    }

    private static void insertSalesOrder(Connection c, UUID id, String billNo,
                                         UUID clientId, int status) throws Exception {
        // sales_orders NOT NULL：bill_no / bill_date / client_id(FK clients) / status。
        try (PreparedStatement ps = c.prepareStatement(
                "INSERT INTO sales_orders(id, bill_no, bill_date, client_id, status) VALUES (?, ?, DATE '2026-08-01', ?, ?)")) {
            ps.setObject(1, id);
            ps.setString(2, billNo);
            ps.setObject(3, clientId);
            ps.setShort(4, (short) status);
            ps.executeUpdate();
        }
    }

    private static void insertSalesOrderItem(Connection c, UUID id, UUID orderId, UUID goodsId,
                                             double qty, double reserved, double shipped,
                                             double returned, double flag, double planned,
                                             double produced, short chainStatus, short priority) throws Exception {
        // sales_order_items NOT NULL：bill_no / bill_date / order_id / goods_id / qty；
        // V90 加 reserved_qty/planned_qty/produced_qty/chain_status（均 NOT NULL DEFAULT 0）；
        // V178 加 priority（NOT NULL DEFAULT 3）。显式写入链路字段以驱动 CASE 分支判定。
        try (PreparedStatement ps = c.prepareStatement("""
                INSERT INTO sales_order_items(
                    id, bill_no, bill_date, order_id, goods_id,
                    goods_code_snapshot, goods_name_snapshot,
                    goods_snapshot_source, goods_snapshot_locked_at,
                    qty, reserved_qty, shipped_qty, returned_qty, flag_qty,
                    planned_qty, produced_qty, chain_status, priority
                ) VALUES (?, ?, DATE '2026-08-01', ?, ?,
                          'TEST-GOODS', 'Test goods', 'MASTER_AT_APPROVAL', now(),
                          ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)) {
            ps.setObject(1, id);
            ps.setString(2, "SOI-" + id);
            ps.setObject(3, orderId);
            ps.setObject(4, goodsId);
            ps.setDouble(5, qty);
            ps.setDouble(6, reserved);
            ps.setDouble(7, shipped);
            ps.setDouble(8, returned);
            ps.setDouble(9, flag);
            ps.setDouble(10, planned);
            ps.setDouble(11, produced);
            ps.setShort(12, chainStatus);
            ps.setShort(13, priority);
            ps.executeUpdate();
        }
    }

    // ============================ 通用助手 ============================

    private static void setNullableUuid(PreparedStatement ps, int index, UUID value) throws Exception {
        if (value == null) {
            // CAST(NULL AS uuid) 需 OTHER 类型，避免驱动按默认类型绑定失败。
            ps.setNull(index, Types.OTHER);
        } else {
            ps.setObject(index, value);
        }
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }
}
