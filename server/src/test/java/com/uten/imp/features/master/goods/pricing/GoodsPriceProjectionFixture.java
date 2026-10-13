package com.uten.imp.features.master.goods.pricing;

import com.uten.imp.support.MigratedProjectionSchema;
import java.util.UUID;
import org.springframework.jdbc.core.JdbcTemplate;

/** Full migrated column shapes for isolated price-reader oracles. Approval and
 * frozen-label defaults below describe these tests' already approved facts. */
final class GoodsPriceProjectionFixture {
    private GoodsPriceProjectionFixture() { }

    static void history(JdbcTemplate db, String frozenCode) {
        MigratedProjectionSchema.createCurrentTables(db,
                "goods", "units", "currencies", "suppliers", "colors", "clients",
                "purchase_orders", "purchase_order_items", "subcontract_orders", "subcontract_order_items",
                "sales_orders", "sales_order_items", "procurement_order_approval_cases",
                "procurement_order_approval_events", "sales_quotes", "sales_quote_revision_logs",
                "permissions", "permission_surfaces", "permission_surface_permissions",
                "departments", "department_permissions");
        for (String kind : new String[]{"purchase", "subcontract", "sales"}) {
            db.execute("ALTER TABLE " + kind + "_orders ALTER COLUMN status SET DEFAULT 1");
            db.execute("ALTER TABLE " + kind + "_order_items ALTER COLUMN goods_code_snapshot SET DEFAULT '"
                    + frozenCode.replace("'", "''") + "', ALTER COLUMN goods_name_snapshot SET DEFAULT 'Frozen item'");
        }
        db.execute("ALTER TABLE sales_orders ALTER COLUMN approved_at SET DEFAULT now()");
        db.execute("ALTER TABLE procurement_order_approval_cases ALTER COLUMN decided_at SET DEFAULT now()");
    }

    static UUID salesClient(JdbcTemplate db, UUID owner) {
        UUID client = UUID.randomUUID();
        db.update("INSERT INTO clients(id,name,owner_employee_id) VALUES(?,'Price fixture client',?)", client, owner);
        return client;
    }
}
