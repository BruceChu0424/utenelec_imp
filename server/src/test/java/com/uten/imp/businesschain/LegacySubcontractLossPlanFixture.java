package com.uten.imp.businesschain;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;

/** Historical, pre-V961 plans for regression tests of the original finished-goods tolerance contract. */
final class LegacySubcontractLossPlanFixture {
    private LegacySubcontractLossPlanFixture() { }

    static void seedBeforeAnyExecution(JdbcTemplate db, PlatformTransactionManager transactions, UUID orderId) {
        new TransactionTemplate(transactions).executeWithoutResult(tx -> {
            assertEquals(0, db.queryForObject("""
                    SELECT COUNT(*) FROM subcontract_material_issue_items issue_item
                    JOIN subcontract_order_items order_item ON order_item.id=issue_item.order_item_id
                    WHERE order_item.order_id=?
                    """, Integer.class, orderId), "Historical fixture must be seeded before any issue exists");
            assertEquals(0, db.queryForObject("""
                    SELECT COUNT(*) FROM subcontract_receipt_items receipt_item
                    JOIN subcontract_order_items order_item ON order_item.id=receipt_item.order_item_id
                    WHERE order_item.order_id=?
                    """, Integer.class, orderId), "Historical fixture must be seeded before any receipt exists");
            List<Map<String, Object>> rows = db.queryForList("""
                    SELECT line.* FROM subcontract_material_plan_items line
                    JOIN subcontract_material_plans plan ON plan.id=line.plan_id
                    WHERE plan.order_id=? AND NOT line.is_deleted AND line.material_loss_pct>0
                    ORDER BY line.id FOR UPDATE OF line
                    """, orderId);
            // Explicit historical import, confined to this test transaction. The production
            // update guard stays enabled; only new fixture rows are inserted, never mutable
            // execution facts. All actions under test run with the ordinary origin guards.
            db.execute("SET LOCAL session_replication_role = replica");
            try {
                for (Map<String, Object> row : rows) {
                    assertEquals(0, ((BigDecimal) row.get("issued_qty")).signum());
                    BigDecimal base = (BigDecimal) row.get("base_bom_unit_qty");
                    BigDecimal planned = db.queryForObject("""
                            SELECT fn_subcontract_draw_f(qty, ?) FROM subcontract_order_items WHERE id=?
                            """, BigDecimal.class, base, row.get("order_item_id"));
                    row.put("bom_unit_qty", base);
                    row.put("material_loss_pct", BigDecimal.ZERO);
                    row.put("planned_qty", planned);
                    assertEquals(1, db.update("DELETE FROM subcontract_material_plan_items WHERE id=?", row.get("id")));
                    List<String> columns = new ArrayList<>(row.keySet());
                    db.update("INSERT INTO subcontract_material_plan_items (" + String.join(",", columns)
                                    + ") VALUES (" + String.join(",", java.util.Collections.nCopies(columns.size(), "?")) + ")",
                            columns.stream().map(row::get).toArray());
                }
            } finally {
                db.execute("SET LOCAL session_replication_role = origin");
            }
        });
    }
}
