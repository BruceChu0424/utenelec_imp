package com.uten.imp.legacy.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class LegacyPurchaseUnitFallbackContractTest {

    @Test
    void allPurchaseItemImportsUseOnlyTheDeterministicBaseUnitFallback()
            throws IOException {
        Path script = Path.of(
                System.getProperty("user.dir"),
                "legacy_migration",
                "migrate_purchase.sql");
        String sql = Files.readString(script, StandardCharsets.UTF_8);

        assertEquals(4, occurrences(sql, "NULLIF(s.unit_legacy_id, 0)"));
        assertEquals(4, occurrences(sql, "COALESCE(s.unit_legacy_id, 0) = 0"));
        assertEquals(4, occurrences(sql, "COALESCE(s.unit_rate, 1) = 1"));
        assertEquals(4, occurrences(sql, "u.legacy_id = g.unit_legacy_id"));
        assertFalse(sql.contains(
                "(SELECT id FROM units  WHERE legacy_id = s.unit_legacy_id)"));
        assertTrue(sql.contains("待治理 采购全链明细单位无法确定"));
        assertTrue(sql.contains("阻塞MRP 未完成订货明细单位无法确定"));
    }

    private static int occurrences(String value, String needle) {
        int count = 0;
        int from = 0;
        while ((from = value.indexOf(needle, from)) >= 0) {
            count++;
            from += needle.length();
        }
        return count;
    }
}
