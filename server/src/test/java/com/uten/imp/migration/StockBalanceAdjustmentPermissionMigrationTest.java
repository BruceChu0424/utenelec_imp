package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class StockBalanceAdjustmentPermissionMigrationTest {

    @Test
    void privilegedAdjustmentPermissionIsInstalledWithoutBroadDepartmentGrant()
            throws IOException {
        String sql;
        try (var stream = getClass().getResourceAsStream(
                "/db/migration/V167__privileged_stock_balance_adjustment.sql")) {
            if (stream == null) {
                throw new IOException("V167 migration resource is missing");
            }
            sql = new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        }

        assertTrue(sql.contains("'stock:balance:adjust'"));
        assertFalse(sql.contains("department_permissions"));
        assertTrue(sql.contains(
                "ux_stock_documents_authorized_balance_adjustment_source"));
        assertTrue(sql.contains("AUTHORIZED_BALANCE_ADJUSTMENT:%"));
        assertTrue(sql.contains("stock_movements.created_by"));
    }
}
