package com.uten.imp.businesschain;

import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;

import java.sql.SQLException;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Adversarial writes against a custody bridge created by the actual purchase/IQC/outbound chain. */
final class SubcontractComponentHandoffGuardAssertions {
    private SubcontractComponentHandoffGuardAssertions() {}

    static void verify(JdbcTemplate db, UUID handoffId) {
        Map<String, Object> bridge = db.queryForMap(
                "SELECT * FROM subcontract_component_stock_handoffs WHERE id=?", handoffId);
        UUID sourceId = (UUID) bridge.get("source_reservation_id");
        UUID targetId = (UUID) bridge.get("target_reservation_id");
        for (UUID reservationId : List.of(sourceId, targetId)) {
            Map<String, Object> reservationBefore = db.queryForMap(
                    "SELECT * FROM stock_reservations WHERE id=?", reservationId);
            // The original exact source is already protected by several earlier BEFORE guards
            // (qualified-origin identity, exact warehouse identity, and this custody guard).
            // Their execution order is not the contract: require a controlled CHECK rejection
            // and an unchanged row. The new outbound target must exercise our new guard.
            String[] identityGuards = reservationId.equals(sourceId)
                    ? new String[0]
                    : new String[]{"subcontract_component_reservation_identity"};
            for (String field : List.of("owner_id", "goods_id", "warehouse_id", "source_doc_id", "supply_id")) {
                rejects(() -> db.update("UPDATE stock_reservations SET " + field + "=? WHERE id=?",
                                UUID.randomUUID(), reservationId),
                        identityGuards);
            }
            rejects(() -> db.update("UPDATE stock_reservations SET is_deleted=TRUE WHERE id=?", reservationId),
                    identityGuards);
            rejects(() -> db.update("DELETE FROM stock_reservations WHERE id=?", reservationId),
                    identityGuards);
            assertEquals(reservationBefore, db.queryForMap("SELECT * FROM stock_reservations WHERE id=?", reservationId),
                    "Every rejected identity, soft-delete and delete attempt must preserve the original reservation");
        }
        rejects(() -> db.update("UPDATE stock_reservations SET qty=qty+1 WHERE id=?", targetId),
                "subcontract_component_reservation_identity");
        for (String field : List.of("parent_material_id", "child_material_id")) {
            UUID materialId = (UUID) bridge.get(field);
            rejects(() -> db.update("UPDATE production_material_analysis_materials SET parent_node_key='forged-parent' WHERE id=?", materialId),
                    "subcontract_component_material_identity");
        }
        for (String field : List.of("parent_material_id", "child_material_id")) {
            // Keep the same historical id/release event so the base bridge-shape guard succeeds;
            // lineage must reject the forged parent/child before a duplicate PK or FK can mask it.
            String parent = field.equals("parent_material_id") ? "?::uuid" : "parent_material_id";
            String child = field.equals("child_material_id") ? "?::uuid" : "child_material_id";
            rejects(() -> db.update("""
                    INSERT INTO subcontract_component_stock_handoffs (
                        id,plan_item_id,application_item_id,parent_material_id,child_material_id,
                        source_entitlement_event_id,source_reservation_id,target_reservation_id,
                        release_event_id,qty,created_at,created_by)
                    SELECT id,plan_item_id,application_item_id,%s,%s,
                        source_entitlement_event_id,source_reservation_id,target_reservation_id,
                        release_event_id,qty,created_at,created_by
                    FROM subcontract_component_stock_handoffs WHERE id=?
                    """.formatted(parent, child), UUID.randomUUID(), handoffId),
                    "subcontract_component_handoff_lineage");
        }
        assertEquals(bridge, db.queryForMap("SELECT * FROM subcontract_component_stock_handoffs WHERE id=?", handoffId),
                "Rejected writes must leave the original bridge unchanged");
    }

    private static void rejects(Runnable mutation, String... constraints) {
        DataAccessException failure = assertThrows(DataAccessException.class, mutation::run);
        SQLException sql = null;
        for (Throwable cause = failure; cause != null; cause = cause.getCause()) {
            if (cause instanceof SQLException found) { sql = found; break; }
        }
        assertNotNull(sql);
        assertEquals("23514", sql.getSQLState(), failure.toString());
        SQLException actual = sql;
        assertTrue(constraints.length == 0 || java.util.Arrays.stream(constraints).anyMatch(constraint ->
                        actual.getMessage().contains(constraint) || constraint.equals(serverConstraint(actual))),
                "Expected " + java.util.Arrays.toString(constraints) + ", got " + sql);
    }

    private static String serverConstraint(SQLException sql) {
        return sql instanceof org.postgresql.util.PSQLException postgres && postgres.getServerErrorMessage() != null
                ? postgres.getServerErrorMessage().getConstraint() : null;
    }
}
