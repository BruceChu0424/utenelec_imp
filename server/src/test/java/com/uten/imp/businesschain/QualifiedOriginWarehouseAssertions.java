package com.uten.imp.businesschain;

import com.uten.imp.application.port.ProductionMutationFootprintPort;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.sql.SQLException;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Counterexamples against committed, service-created IQC/warehouse/entitlement facts. */
final class QualifiedOriginWarehouseAssertions {
    private QualifiedOriginWarehouseAssertions() {}

    static void verify(JdbcTemplate db, PlatformTransactionManager manager,
                       ProductionMutationFootprintPort footprints, UUID packageId,
                       UUID plannedWarehouseId, List<UUID> actualWarehouseIds) {
        var transaction = new TransactionTemplate(manager);
        UUID analysisId = db.queryForObject("""
                SELECT plan.material_analysis_id FROM production_plans plan
                JOIN production_material_demands demand ON demand.plan_id=plan.id
                WHERE demand.package_id=? LIMIT 1
                """, UUID.class, packageId);
        var footprint = transaction.execute(status -> footprints.forAnalyses(List.of(analysisId)));
        assertNotNull(footprint);
        assertTrue(footprint.mainWarehouseIds().contains(plannedWarehouseId));
        assertTrue(footprint.mainWarehouseIds().containsAll(actualWarehouseIds),
                "formalized stock must keep every actual warehouse in the initial lock footprint");

        UUID target = db.queryForObject("""
                SELECT target.id FROM stock_reservations target
                JOIN production_material_demands demand ON demand.id=target.demand_id
                JOIN warehouses warehouse ON warehouse.id=target.warehouse_id
                WHERE demand.package_id=? AND target.requires_qualified_origin AND warehouse.is_defective
                ORDER BY target.id LIMIT 1
                """, UUID.class, packageId);
        assertNotNull(target);
        assertEquals(0, db.queryForObject("""
                SELECT count(*) FROM preplan_stock_entitlement_events formalize
                WHERE formalize.event_type='FORMALIZE' AND formalize.target_package_id=?
                  AND NOT fn_preplan_reservation_has_qualified_origin(formalize.stock_reservation_id)
                """, Integer.class, packageId));
        assertFalse(Boolean.TRUE.equals(db.queryForObject(
                "SELECT fn_preplan_reservation_has_qualified_origin(?)", Boolean.class, target)),
                "a formal target is not itself an immutable original source");
        assertFalse(Boolean.TRUE.equals(db.queryForObject(
                "SELECT fn_preplan_reservation_has_qualified_origin(?)", Boolean.class, UUID.randomUUID())));

        String before = snapshot(db, packageId);
        UUID source = db.queryForObject("""
                SELECT stock_reservation_id FROM preplan_stock_entitlement_events
                WHERE event_type='FORMALIZE' AND target_stock_reservation_id=? ORDER BY id LIMIT 1
                """, UUID.class, target);
        String sourceBefore = db.queryForObject("SELECT to_jsonb(reservation)::text FROM stock_reservations reservation WHERE id=?", String.class, source);
        rejected(() -> transaction.execute(status -> {
            db.update("UPDATE stock_reservations SET source_doc_id=? WHERE id=?", UUID.randomUUID(), source);
            return null;
        }), "exact source reservation identity and original quantity are immutable");
        assertEquals(sourceBefore, db.queryForObject("SELECT to_jsonb(reservation)::text FROM stock_reservations reservation WHERE id=?", String.class, source));

        rejected(() -> transaction.execute(status -> {
            db.update("UPDATE stock_reservations SET requires_qualified_origin=FALSE WHERE id=?", target);
            return null;
        }), "qualified-origin requirement is immutable");
        assertEquals(before, snapshot(db, packageId));

        // The row UPDATE itself is valid. Explicitly flush this deferred check
        // before the older execution/DRAW conservation checks, which also reject
        // the same incomplete reversal. No existing guard is disabled.
        boolean[] updated = {false};
        rejected(() -> transaction.execute(status -> {
            assertEquals(1, db.update("UPDATE stock_reservations SET released_qty=released_qty+1 WHERE id=?", target));
            updated[0] = true;
            db.execute("SET CONSTRAINTS trg_qualified_origin_target_coverage IMMEDIATE");
            return null;
        }), "qualified target reservation requires complete same-warehouse formal provenance");
        assertTrue(updated[0], "coverage must be deferred until all forward/reverse facts are present");
        assertEquals(before, snapshot(db, packageId));

        // A caller cannot omit the marker and borrow arbitrary public stock in
        // this same defective/cross-main warehouse, even with a real demand ID.
        UUID forged = UUID.randomUUID();
        rejected(() -> transaction.execute(status -> {
            db.update("""
                    INSERT INTO stock_reservations
                    SELECT (jsonb_populate_record(NULL::stock_reservations,
                        to_jsonb(source.*)||jsonb_build_object('id',CAST(? AS uuid),
                          'qty',1,'released_qty',0,'consumed_qty',0,
                          'requires_qualified_origin',FALSE))).*
                    FROM stock_reservations source WHERE source.id=?
                    """, forged, target);
            return null;
        }), null);
        assertEquals(0, db.queryForObject("SELECT count(*) FROM stock_reservations WHERE id=?", Integer.class, forged));
        assertEquals(before, snapshot(db, packageId));
    }

    private static String snapshot(JdbcTemplate db, UUID packageId) {
        return db.queryForObject("""
                SELECT jsonb_agg(to_jsonb(reservation) ORDER BY reservation.id)::text
                FROM stock_reservations reservation JOIN production_material_demands demand ON demand.id=reservation.demand_id
                WHERE demand.package_id=?
                """, String.class, packageId);
    }

    private static void rejected(Runnable mutation, String message) {
        RuntimeException rejected = assertThrows(RuntimeException.class, mutation::run);
        SQLException sql = null;
        for (Throwable current = rejected; current != null; current = current.getCause()) {
            if (current instanceof SQLException failure) { sql = failure; break; }
        }
        assertNotNull(sql, "the real database must reject this counterexample");
        assertEquals("23514", sql.getSQLState(), sql.getMessage());
        if (message != null) assertTrue(sql.getMessage().contains(message), sql.getMessage());
    }
}
