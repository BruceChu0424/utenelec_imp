package com.uten.imp.features.warehouse.inbound;

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
import java.sql.SQLException;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Real PostgreSQL proof for V222 procurement/subcontract IQC quarantine.
 *
 * <p>The quarantine is a sidecar kept deliberately outside {@code stock_balances}: a pending
 * receipt therefore never counts as available ATP, can't be reserved, and can't wake production.
 * Only a controlled PASS disposition (in the service) calls {@code recordMovement(DIR_IN)}. These
 * tests pin the DB-level invariants the service relies on: pending qty is absent from
 * stock_balances, the resolved ≤ received + status-projection CHECKs, and the append-only guard.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProcurementInspectionQuarantinePostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

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
    void pendingQuarantineDoesNotEnterStockBalances() throws Exception {
        Fixture fx = insertPendingInspection("10.0000");
        try (Connection c = connection()) {
            // A pending IQC row exists for (warehouse, goods) with received 10...
            try (PreparedStatement q = c.prepareStatement("""
                    SELECT COALESCE((
                        SELECT qty FROM stock_balances
                        WHERE warehouse_id = ? AND goods_id = ?
                    ), 0)
                    """)) {
                q.setObject(1, fx.warehouseId());
                q.setObject(2, fx.goodsId());
                try (var rs = q.executeQuery()) {
                    assertTrue(rs.next());
                    assertEquals(0, new BigDecimal(rs.getString(1)).compareTo(BigDecimal.ZERO),
                            "待检品不得计入 stock_balances / 可用量");
                }
            }
        }
    }

    @Test
    void resolvedCannotExceedReceived() throws Exception {
        Fixture fx = insertPendingInspection("10.0000");
        try (Connection c = connection()) {
            SQLException ex = assertThrows(SQLException.class, () ->
                    update(c, "UPDATE procurement_inspection_items SET passed_base_qty = '11.0000' WHERE id = ?",
                            fx.inspectionItemId()));
            assertEquals("23514", ex.getSQLState());
        }
    }

    @Test
    void statusProjectionMustMatchQuantities() throws Exception {
        try (Connection c = connection()) {
            Fixture dims = insertGoodsAndWarehouse(c);
            // status RESOLVED but nothing resolved → projection violation.
            try (PreparedStatement s = c.prepareStatement("""
                    INSERT INTO procurement_inspection_items (
                        id, receipt_type, receipt_id, receipt_item_id, warehouse_id, goods_id,
                        unit_rate, received_base_qty, status)
                    VALUES (?, 'PURCHASE', ?, ?, ?, ?, 1, '5.0000', 'RESOLVED')
                    """)) {
                s.setObject(1, UUID.randomUUID());
                s.setObject(2, UUID.randomUUID());
                s.setObject(3, UUID.randomUUID());
                s.setObject(4, dims.warehouseId());
                s.setObject(5, dims.goodsId());
                SQLException ex = assertThrows(SQLException.class, s::executeUpdate);
                assertEquals("23514", ex.getSQLState());
            }
        }
    }

    @Test
    void inspectionEventsAreAppendOnly() throws Exception {
        Fixture fx = insertPendingInspection("8.0000");
        UUID eventId = UUID.randomUUID();
        try (Connection c = connection()) {
            try (PreparedStatement s = c.prepareStatement("""
                    INSERT INTO procurement_inspection_events (
                        id, inspection_item_id, action, base_qty, reason, actor_employee_id, occurred_at)
                    VALUES (?, ?, 'RECEIVED', '8.0000', NULL, ?, now())
                    """)) {
                s.setObject(1, eventId);
                s.setObject(2, fx.inspectionItemId());
                s.setObject(3, UUID.randomUUID());
                assertEquals(1, s.executeUpdate());
            }
            try (PreparedStatement u = c.prepareStatement(
                    "UPDATE procurement_inspection_events SET reason = 'tampered' WHERE id = ?")) {
                u.setObject(1, eventId);
                SQLException ex = assertThrows(SQLException.class, u::executeUpdate);
                assertEquals("55000", ex.getSQLState());
                assertTrue(ex.getMessage().contains("append-only"));
            }
            try (PreparedStatement d = c.prepareStatement(
                    "DELETE FROM procurement_inspection_events WHERE id = ?")) {
                d.setObject(1, eventId);
                SQLException ex = assertThrows(SQLException.class, d::executeUpdate);
                assertEquals("55000", ex.getSQLState());
            }
        }
    }

    private Fixture insertPendingInspection(String receivedBase) throws Exception {
        try (Connection c = connection()) {
            Fixture dims = insertGoodsAndWarehouse(c);
            UUID inspectionItemId = UUID.randomUUID();
            try (PreparedStatement s = c.prepareStatement("""
                    INSERT INTO procurement_inspection_items (
                        id, receipt_type, receipt_id, receipt_item_id, warehouse_id, goods_id,
                        unit_rate, received_base_qty)
                    VALUES (?, 'PURCHASE', ?, ?, ?, ?, 1, ?)
                    """)) {
                s.setObject(1, inspectionItemId);
                s.setObject(2, UUID.randomUUID());
                s.setObject(3, UUID.randomUUID());
                s.setObject(4, dims.warehouseId());
                s.setObject(5, dims.goodsId());
                s.setBigDecimal(6, new BigDecimal(receivedBase));
                assertEquals(1, s.executeUpdate());
            }
            return new Fixture(dims.goodsId(), dims.warehouseId(), inspectionItemId);
        }
    }

    private static Fixture insertGoodsAndWarehouse(Connection c) throws Exception {
        UUID goodsId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        try (PreparedStatement g = c.prepareStatement(
                "INSERT INTO goods(id, code, name, min_qty) VALUES (?, ?, ?, 0)")) {
            g.setObject(1, goodsId);
            g.setString(2, "G-IQC-" + goodsId);
            g.setString(3, "IQC test goods");
            assertEquals(1, g.executeUpdate());
        }
        try (PreparedStatement w = c.prepareStatement(
                "INSERT INTO warehouses(id, code, name) VALUES (?, ?, ?)")) {
            w.setObject(1, warehouseId);
            w.setString(2, "W-IQC-" + warehouseId);
            w.setString(3, "IQC test warehouse");
            assertEquals(1, w.executeUpdate());
        }
        return new Fixture(goodsId, warehouseId, null);
    }

    private static void update(Connection c, String sql, UUID id) throws Exception {
        try (PreparedStatement s = c.prepareStatement(sql)) {
            s.setObject(1, id);
            s.executeUpdate();
        }
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }

    private record Fixture(UUID goodsId, UUID warehouseId, UUID inspectionItemId) {
    }
}
