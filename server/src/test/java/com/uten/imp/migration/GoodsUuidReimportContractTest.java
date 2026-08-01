package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class GoodsUuidReimportContractTest {

    @Test
    void goodsReimportWritesAllSixUuidLanesByUniqueLegacyIdOnly() throws IOException {
        String sql = sourceFile("legacy_migration/migrate_goods_data.sql");
        String normalized = sql.replaceAll("\\s+", " ");

        assertTrue(normalized.contains(
                "unit_id, color_id, mould_id, client_id, default_supplier_id, secondary_supplier_id"));
        assertTrue(normalized.contains("u.legacy_id = NULLIF(gs.unit_legacy_id, 0)"));
        assertTrue(normalized.contains("c.legacy_id = NULLIF(gs.color_legacy_id, 0)"));
        assertTrue(normalized.contains("m.legacy_id = NULLIF(gs.mould_legacy_id, 0)"));
        assertTrue(normalized.contains("c.legacy_id = NULLIF(gs.client_legacy_id, 0)"));
        assertTrue(normalized.contains("s.legacy_id = NULLIF(gs.vend_legacy_id, 0)"));
        assertTrue(normalized.contains("s.legacy_id = NULLIF(gs.vend2_legacy_id, 0)"));
        assertFalse(normalized.toLowerCase().contains(" where lower("));
    }

    @Test
    void bomReimportWritesUuidLanesAndKeepsV181StubIsolation() throws IOException {
        String sql = sourceFile("legacy_migration/migrate_goods_bom.sql");
        String normalized = sql.replaceAll("\\s+", " ");

        assertTrue(normalized.contains("color_id, default_supplier_id"));
        assertTrue(normalized.contains(
                "color_master.legacy_id = NULLIF(bs.color_legacy_id, 0)"));
        assertTrue(normalized.contains(
                "supplier_master.legacy_id = NULLIF(bs.vend_legacy_id, 0)"));
        assertTrue(normalized.contains("g.auto_created = FALSE"));
        assertTrue(normalized.contains("c.auto_created = FALSE"));
        assertFalse(normalized.toLowerCase().contains(" where lower("));
    }

    private static String sourceFile(String serverRelativePath) throws IOException {
        Path direct = Path.of(serverRelativePath);
        Path path = Files.exists(direct) ? direct : Path.of("server").resolve(serverRelativePath);
        return Files.readString(path, StandardCharsets.UTF_8);
    }
}
