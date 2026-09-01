package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class PurchaseCommercialPricePermissionMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V439__purchase_commercial_price_permissions.sql");

    @Test
    void migrationIsExactPageCatalogWithNoGrantExpansion() throws IOException {
        String sql = Files.readString(MIGRATION);

        assertTrue(sql.contains("'purchase_order:price:view'"));
        assertTrue(sql.contains("'purchase_return:price:view'"));
        assertTrue(sql.contains("'purchase_report:price:view'"));
        assertTrue(sql.contains("('purchase.order', 'purchase_order:price:view')"));
        assertTrue(sql.contains("('purchase.return', 'purchase_return:price:view')"));
        assertTrue(sql.contains("('purchase.report', 'purchase_report:price:view')"));
        assertTrue(sql.contains(
                "V439 refuses to activate pre-existing purchase price grants"));
        assertTrue(sql.contains(
                "V439 purchase price permissions must start with zero grants"));
        assertTrue(sql.contains("action_type = EXCLUDED.action_type"));

        assertFalse(sql.contains("INSERT INTO department_permissions"));
        assertFalse(sql.contains("INSERT INTO role_permissions"));
        assertFalse(sql.contains("INSERT INTO user_permission_overrides"));
        assertFalse(sql.contains("INSERT INTO manager_permission_delegations"));
        assertFalse(sql.contains("procurement_iqc_rejection:"));
    }
}
