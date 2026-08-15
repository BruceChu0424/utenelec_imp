package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class GoodsMeasurementUnitUuidMigrationContractTest {

    @Test
    void v259IsRerunnableFailClosedAndInstallsConstraintsBeforeBackfill() throws IOException {
        String sql = sourceFile("src/main/resources/db/migration/V259__goods_measurement_unit_uuid.sql");
        String normalized = sql.replaceAll("\\s+", " ");

        assertTrue(normalized.contains("ADD COLUMN IF NOT EXISTS thickness_unit_id UUID"));
        assertTrue(normalized.contains("ADD COLUMN IF NOT EXISTS m_weight_unit_id UUID"));
        assertTrue(normalized.contains("c.conname = 'fk_goods_thickness_unit'"));
        assertTrue(normalized.contains("c.conname = 'fk_goods_m_weight_unit'"));
        assertTrue(normalized.contains("has unexpected definition"));
        assertEquals(1, count(sql, "ADD CONSTRAINT fk_goods_thickness_unit"));
        assertEquals(1, count(sql, "ADD CONSTRAINT fk_goods_m_weight_unit"));
        assertEquals(1, count(sql, "VALIDATE CONSTRAINT fk_goods_thickness_unit"));
        assertEquals(1, count(sql, "VALIDATE CONSTRAINT fk_goods_m_weight_unit"));

        int constraintBlock = sql.indexOf("DO $$");
        int lastValidation = sql.lastIndexOf("VALIDATE CONSTRAINT");
        int firstBackfill = sql.indexOf("UPDATE goods g");
        assertTrue(constraintBlock >= 0 && constraintBlock < firstBackfill,
                "FK must be installed before goods trigger events are queued by backfill");
        assertTrue(lastValidation >= 0 && lastValidation < firstBackfill,
                "FK validation must finish before goods trigger events are queued by backfill");
    }

    @Test
    void v259BackfillsOnlyNonZeroUniqueLegacyIdsWithoutNameGuessing() throws IOException {
        String sql = sourceFile("src/main/resources/db/migration/V259__goods_measurement_unit_uuid.sql");
        String normalized = sql.replaceAll("\\s+", " ").toLowerCase();

        assertEquals(2, count(normalized, "having count(*) = 1"));
        assertTrue(normalized.contains("g.thickness_unit_legacy_id is not null"));
        assertTrue(normalized.contains("g.thickness_unit_legacy_id <> 0"));
        assertTrue(normalized.contains("g.m_weight_unit_legacy_id is not null"));
        assertTrue(normalized.contains("g.m_weight_unit_legacy_id <> 0"));
        assertTrue(normalized.contains("g.thickness_unit_legacy_id = u.legacy_id"));
        assertTrue(normalized.contains("g.m_weight_unit_legacy_id = u.legacy_id"));
        assertTrue(!normalized.contains("lower("));
        assertTrue(!normalized.contains("u.name"));
    }

    private static int count(String source, String token) {
        int result = 0;
        for (int offset = 0; (offset = source.indexOf(token, offset)) >= 0; offset += token.length()) {
            result++;
        }
        return result;
    }

    private static String sourceFile(String serverRelativePath) throws IOException {
        Path direct = Path.of(serverRelativePath);
        Path path = Files.exists(direct) ? direct : Path.of("server").resolve(serverRelativePath);
        return Files.readString(path, StandardCharsets.UTF_8);
    }
}
