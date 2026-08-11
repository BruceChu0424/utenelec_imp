package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionExactDemandSnapshotMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V248__production_exact_material_demand_snapshot.sql");

    @Test
    void exactSnapshotHasAnExplicitModeQuantityAndRuleFingerprint() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("requirement_mode text not null default 'linear'")
                .contains("required_for_product_qty numeric(18,4)")
                .contains("requirement_fingerprint varchar(64)")
                .contains("requirement_mode = 'linear' and required_for_product_qty is null and requirement_fingerprint is null")
                .contains("requirement_mode = 'exact_snapshot' and execution_segment_id is not null")
                .contains("required_for_product_qty > 0")
                .contains("requirement_fingerprint ~ '^[0-9a-f]{64}$'");
    }

    @Test
    void linearGuardKeepsTheHistoricalRateFormula() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("create or replace function fn_assert_execution_segment_integrity")
                .contains("requirement_mode = 'linear' and required_qty is distinct from ceil((v_segment.planned_qty * per_product_qty) * 10000) / 10000")
                .contains("requirement_mode = 'exact_snapshot' and required_for_product_qty is distinct from v_segment.planned_qty");
    }

    @Test
    void exactSnapshotIdentityCannotBeSilentlyRecalculated() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("create or replace function fn_guard_exact_production_demand_snapshot()")
                .contains("new.required_qty is distinct from old.required_qty")
                .contains("new.per_product_qty is distinct from old.per_product_qty")
                .contains("new.required_for_product_qty is distinct from old.required_for_product_qty")
                .contains("new.requirement_fingerprint is distinct from old.requirement_fingerprint")
                .contains("production_material_demand_exact_snapshot_guard");
    }

    private static String compact() throws Exception {
        return Files.readString(MIGRATION, StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}
