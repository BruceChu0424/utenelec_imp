package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class MaterialAnalysisUuidFallbackContractTest {

    @Test
    void bomExpansionNeverConvertsLegacyColorOrUnitShadowsIntoUuidRelations()
            throws IOException {
        String source = canonical(sourceFile(
                "src/main/java/com/uten/imp/features/production/analysis/MaterialAnalysisBomSnapshotReader.java"));

        assertThat(source)
                .doesNotContain("legacy_color")
                .doesNotContain("legacy_unit")
                .doesNotContain("resolved_color.legacy_id")
                .contains(canonical(
                        "LEFT JOIN colors resolved_color ON resolved_color.id = COALESCE(b.color_id, component.color_id)"))
                .contains(canonical(
                        "LEFT JOIN units component_unit ON component_unit.id = component.unit_id"));

        // Legacy-only color shadows are detected as invalid data; they are never
        // dereferenced to manufacture a UUID for a new analysis material row.
        assertThat(source)
                .contains(canonical("""
                        b.color_id IS NULL
                        AND NULLIF(b.color_legacy_id,0) IS NOT NULL
                        """))
                .contains(canonical("""
                        component.color_id IS NULL
                        AND NULLIF(component.color_legacy_id,0) IS NOT NULL
                        """));
    }

    @Test
    void manualSourceRequiresTheGoodsCanonicalBaseUnitUuid() throws IOException {
        String source = canonical(sourceFile(
                "src/main/java/com/uten/imp/features/production/analysis/MaterialAnalysisService.java"));
        assertThat(source)
                .contains("g.unit_id AS base_unit_id")
                .doesNotContain("legacy_unit.id AS base_unit_id")
                .doesNotContain("legacy_unit.legacy_id = g.unit_legacy_id");
    }

    private static String sourceFile(String serverRelativePath) throws IOException {
        Path direct = Path.of(serverRelativePath);
        Path path = Files.exists(direct) ? direct : Path.of("server").resolve(serverRelativePath);
        return Files.readString(path, StandardCharsets.UTF_8);
    }

    private static String canonical(String value) {
        return value.replaceAll("\\s+", " ").trim();
    }
}
