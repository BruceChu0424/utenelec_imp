package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertTrue;

class PurchaseUnitNormalizationMigrationTest {

    @Test
    void onlyDeterministicLegacyUnitOmissionsAreBackfilled() throws IOException {
        String sql;
        try (var stream = getClass().getResourceAsStream(
                "/db/migration/V168__normalize_legacy_purchase_item_units.sql")) {
            if (stream == null) {
                throw new IOException("V168 migration resource is missing");
            }
            sql = new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        }

        for (String table : List.of(
                "purchase_request_items",
                "purchase_order_items",
                "purchase_receipt_items",
                "purchase_return_items")) {
            assertTrue(sql.contains("UPDATE " + table + " i"));
        }
        assertTrue(sql.contains("u.legacy_id = g.unit_legacy_id"));
        assertTrue(sql.contains("i.legacy_id IS NOT NULL"));
        assertTrue(sql.contains("i.unit_id IS NULL"));
        assertTrue(sql.contains("COALESCE(i.unit_rate, 1) = 1"));
        assertTrue(sql.contains("SET unit_id = u.id"));
        assertTrue(sql.contains("unit_rate = 1"));
    }
}
