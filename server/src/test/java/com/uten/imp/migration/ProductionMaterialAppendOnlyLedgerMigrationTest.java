package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.assertTrue;

class ProductionMaterialAppendOnlyLedgerMigrationTest {

    @Test
    void migrationMakesAllMaterialLedgersAppendOnly() throws IOException {
        String sql;
        try (var stream = getClass().getResourceAsStream(
                "/db/migration/"
                        + "V161__production_material_ledgers_append_only.sql")) {
            if (stream == null) {
                throw new IOException("V161 migration resource is missing");
            }
            sql = new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        }

        assertTrue(sql.contains(
                "fn_reject_production_material_ledger_mutation"));
        assertTrue(sql.contains(
                "BEFORE UPDATE OR DELETE ON production_material_stock_events"));
        assertTrue(sql.contains(
                "BEFORE UPDATE OR DELETE ON production_material_stock_postings"));
        assertTrue(sql.contains(
                "BEFORE UPDATE OR DELETE ON production_material_settlement_events"));
        assertTrue(sql.contains(
                "BEFORE UPDATE OR DELETE ON "
                        + "production_material_settlement_postings"));
        assertTrue(sql.contains("ON DELETE RESTRICT"));
        assertTrue(sql.contains("ENABLE ALWAYS TRIGGER"));
        assertTrue(sql.contains(
                "Append the matching reversal event and posting instead."));
    }
}
