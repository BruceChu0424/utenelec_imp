package com.uten.imp.features.subcontract.material_issue;

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
import java.time.LocalDate;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Real PostgreSQL proof for V221 subcontract material conservation.
 *
 * <p>The conservation identity {@code supplier_ending = at_supplier_qty − consumed_qty −
 * returned_qty − wasted_qty} is a GENERATED STORED column with {@code CHECK (supplier_ending >= 0)},
 * so it is enforced at the DB for ALL three consumption paths (receipt consume, material return,
 * waste) — not just the receipt path. These tests pin that invariant directly, including the case
 * the legacy V132 trigger cannot catch (returned+wasted ≤ qty but consumed makes the supplier
 * balance negative).
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SubcontractMaterialConservationPostgresTest {

    private static final java.util.concurrent.atomic.AtomicInteger BUSINESS_IDENTIFIER_SEQUENCE =
            new java.util.concurrent.atomic.AtomicInteger();

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
    void supplierEndingStartsAtIssuedQtyAndTracksConsumption() throws Exception {
        UUID issueItemId = setupIssueItem("100.0000", "2.000000");
        try (Connection c = connection()) {
            assertEquals(bd("100.0000"), readSupplierEnding(c, issueItemId));

            // Consume 30 (receipt of 15 finished units × frozen_unit_qty 2) → ending 70.
            update(c, "UPDATE subcontract_material_issue_items SET consumed_qty = '30.0000' WHERE id = ?",
                    issueItemId);
            assertEquals(bd("70.0000"), readSupplierEnding(c, issueItemId));
        }
    }

    @Test
    void overConsumptionIsRejected() throws Exception {
        UUID issueItemId = setupIssueItem("100.0000", "2.000000");
        try (Connection c = connection()) {
            SQLException ex = assertThrows(SQLException.class, () ->
                    update(c, "UPDATE subcontract_material_issue_items SET consumed_qty = '101.0000' WHERE id = ?",
                            issueItemId));
            assertEquals("23514", ex.getSQLState());
        }
    }

    @Test
    void returnedAndWastedAlsoReduceSupplierEnding() throws Exception {
        UUID issueItemId = setupIssueItem("100.0000", "2.000000");
        try (Connection c = connection()) {
            update(c, "UPDATE subcontract_material_issue_items SET consumed_qty = '30.0000' WHERE id = ?",
                    issueItemId);
            // Material return 50 → ending 100−30−50 = 20 (V132 allows: returned 50 ≤ qty 100).
            update(c, "UPDATE subcontract_material_issue_items SET returned_qty = '50.0000' WHERE id = ?",
                    issueItemId);
            assertEquals(bd("20.0000"), readSupplierEnding(c, issueItemId));

            // Waste 25 → ending 100−30−50−25 = −5 → rejected, even though V132 only checks
            // returned(50)+wasted(25) ≤ qty(100) and would otherwise permit it.
            SQLException ex = assertThrows(SQLException.class, () ->
                    update(c, "UPDATE subcontract_material_issue_items SET wasted_qty = '25.0000' WHERE id = ?",
                            issueItemId));
            assertEquals("23514", ex.getSQLState());
        }
    }

    /** at_supplier_qty backfilled to qty keeps historical rows (with returned/wasted) consistent. */
    @Test
    void legacyRowWithReturnedAndWastedSatisfiesCheckWhenBackfilled() throws Exception {
        // qty 100, already returned 20 + wasted 10 historically → at_supplier must be ≥ 30.
        UUID issueItemId = UUID.randomUUID();
        try (Connection c = connection()) {
            UUID goodsId = insertGoods(c);
            UUID issueId = insertIssue(c);
            try (PreparedStatement s = c.prepareStatement("""
                    INSERT INTO subcontract_material_issue_items (
                        id, issue_id, goods_id, bill_no, bill_date, qty, at_supplier_qty,
                        returned_qty, wasted_qty, consumed_qty,
                        goods_code_snapshot, goods_name_snapshot, goods_snapshot_source)
                    VALUES (?, ?, ?, ?, ?, '100.0000', '100.0000', '20.0000', '10.0000', '0.0000',
                            'FIXTURE', 'Fixture goods', 'MASTER_AT_SAVE')
                    """)) {
                s.setObject(1, issueItemId);
                s.setObject(2, issueId);
                s.setObject(3, goodsId);
                s.setString(4, "EC-LG-" + issueItemId);
                s.setObject(5, LocalDate.of(2026, 8, 6));
                assertEquals(1, s.executeUpdate());
            }
            // ending = 100 − 0 − 20 − 10 = 70 (consistent; backfill made at_supplier = qty).
            assertEquals(bd("70.0000"), readSupplierEnding(c, issueItemId));
        }
        assertTrue(issueItemId != null);
    }

    private UUID setupIssueItem(String atSupplier, String frozenUnitQty) throws Exception {
        try (Connection c = connection()) {
            UUID goodsId = insertGoods(c);
            UUID issueId = insertIssue(c);
            UUID issueItemId = UUID.randomUUID();
            try (PreparedStatement s = c.prepareStatement("""
                    INSERT INTO subcontract_material_issue_items (
                        id, issue_id, goods_id, bill_no, bill_date, qty, at_supplier_qty, frozen_unit_qty,
                        goods_code_snapshot, goods_name_snapshot, goods_snapshot_source)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'FIXTURE', 'Fixture goods', 'MASTER_AT_SAVE')
                    """)) {
                s.setObject(1, issueItemId);
                s.setObject(2, issueId);
                s.setObject(3, goodsId);
                s.setString(4, "EC-IT-" + issueItemId);
                s.setObject(5, LocalDate.of(2026, 8, 6));
                s.setBigDecimal(6, new BigDecimal(atSupplier));
                s.setBigDecimal(7, new BigDecimal(atSupplier));
                s.setBigDecimal(8, new BigDecimal(frozenUnitQty));
                assertEquals(1, s.executeUpdate());
            }
            return issueItemId;
        }
    }

    private static UUID insertGoods(Connection c) throws Exception {
        UUID goodsId = UUID.randomUUID();
        try (PreparedStatement s = c.prepareStatement(
                "INSERT INTO goods(id, code, name, min_qty, code_sequence) "
                        + "VALUES (?, ?, ?, 0, (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods))")) {
            s.setObject(1, goodsId);
            s.setString(2, "G-SC-" + goodsId);
            s.setString(3, "Subcontract conservation goods");
            assertEquals(1, s.executeUpdate());
        }
        return goodsId;
    }

    private static UUID insertIssue(Connection c) throws Exception {
        UUID issueId = UUID.randomUUID();
        try (PreparedStatement s = c.prepareStatement(
                "INSERT INTO subcontract_material_issues(id, bill_no, bill_date, status) VALUES (?, ?, ?, 1)")) {
            s.setObject(1, issueId);
            s.setString(2, businessIdentifier("EC", LocalDate.of(2026, 8, 6)));
            s.setObject(3, LocalDate.of(2026, 8, 6));
            assertEquals(1, s.executeUpdate());
        }
        return issueId;
    }

    private static BigDecimal readSupplierEnding(Connection c, UUID issueItemId) throws Exception {
        try (PreparedStatement q = c.prepareStatement(
                "SELECT supplier_ending FROM subcontract_material_issue_items WHERE id = ?")) {
            q.setObject(1, issueItemId);
            try (var rs = q.executeQuery()) {
                assertTrue(rs.next());
                return rs.getBigDecimal(1).stripTrailingZeros();
            }
        }
    }

    private static void update(Connection c, String sql, UUID id) throws Exception {
        try (PreparedStatement s = c.prepareStatement(sql)) {
            s.setObject(1, id);
            s.executeUpdate();
        }
    }

    private static BigDecimal bd(String v) {
        return new BigDecimal(v).stripTrailingZeros();
    }

    private static String businessIdentifier(String prefix, LocalDate date) {
        int sequence = BUSINESS_IDENTIFIER_SEQUENCE.incrementAndGet();
        if (sequence > 999_999) {
            throw new IllegalStateException("test business identifier sequence exhausted");
        }
        return prefix + date.toString().replace("-", "") + "%06d".formatted(sequence);
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }
}
