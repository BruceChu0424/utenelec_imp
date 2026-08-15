package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class GoodsMeasurementUnitUuidContractTest {

    @Test
    void measurementUnitsUseUuidFirstWithDeterministicLegacyBackfill() throws IOException {
        String sql = resource("/db/migration/V259__goods_measurement_unit_uuid.sql");
        String normalized = sql.replaceAll("\\s+", " ");
        assertTrue(normalized.contains("ADD COLUMN IF NOT EXISTS thickness_unit_id UUID"));
        assertTrue(normalized.contains("ADD COLUMN IF NOT EXISTS m_weight_unit_id UUID"));
        assertTrue(normalized.contains("GROUP BY legacy_id HAVING count(*) = 1"));
        assertTrue(normalized.contains("FOREIGN KEY (thickness_unit_id) REFERENCES units(id)"));
        assertTrue(normalized.contains("FOREIGN KEY (m_weight_unit_id) REFERENCES units(id)"));
        assertTrue(normalized.contains("ON DELETE RESTRICT NOT VALID"));
        assertFalse(normalized.contains("DROP COLUMN"));

        String request = resourceSource("features/master/goods/dto/GoodsSaveRequest.java");
        assertTrue(request.contains("private UUID thicknessUnitId"));
        assertTrue(request.contains("private UUID mWeightUnitId"));
        assertTrue(request.contains("hasThicknessUnitReference()"));
        assertTrue(request.contains("hasMWeightUnitReference()"));

        String service = resourceSource("features/master/goods/GoodsService.java");
        assertTrue(service.contains("relationships.unit(req.getThicknessUnitId())"));
        assertTrue(service.contains("relationships.unit(req.getMWeightUnitId())"));
        assertFalse(service.contains("g.setThicknessUnitLegacyId(req.getThicknessUnitLegacyId())"));
        assertFalse(service.contains("g.setMWeightUnitLegacyId(req.getMWeightUnitLegacyId())"));
    }

    private String resource(String path) throws IOException {
        try (var stream = getClass().getResourceAsStream(path)) {
            if (stream == null) throw new IOException("missing resource " + path);
            return new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        }
    }

    private String resourceSource(String suffix) throws IOException {
        var path = java.nio.file.Path.of("src/main/java/com/uten/imp").resolve(suffix);
        if (!java.nio.file.Files.exists(path)) {
            path = java.nio.file.Path.of("server/src/main/java/com/uten/imp").resolve(suffix);
        }
        return java.nio.file.Files.readString(path, StandardCharsets.UTF_8);
    }
}
