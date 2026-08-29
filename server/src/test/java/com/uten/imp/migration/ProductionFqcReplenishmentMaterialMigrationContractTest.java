package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionFqcReplenishmentMaterialMigrationContractTest {

    @Test
    void recoveryDemandReadyAndReverseFactsAreDatabaseGuarded()
            throws IOException {
        String sql = source().replaceAll("\\s+", " ").toLowerCase();

        assertThat(sql)
                .contains("add column fqc_recovery_authorization_id uuid")
                .contains("add column fqc_replenishment_cycle_id uuid")
                .contains("drop constraint production_material_demand_segment_shape_chk")
                .contains("execution_segment_id is null and fqc_replenishment_cycle_id is not null")
                .contains("create table production_fqc_replenishment_attempts")
                .contains("create table production_fqc_replenishment_supply_gaps")
                .contains("create table production_fqc_replenishment_draw_links")
                .contains("create table production_fqc_replenishment_ready_events")
                .contains("production_fqc_replenishment_ready_guard")
                .contains("draw.issue_status is distinct from 2")
                .contains("fulfilled_count <> demand_count")
                .contains("fn_fqc_replenishment_material_ready")
                .contains("production_fqc_material_ready_use_guard")
                .contains("production_fqc_material_cancellation_guard")
                .contains("production_fqc_recovery_material_gate");
    }

    @Test
    void everyNewBusinessLedgerIsAppendOnlyAndAudited()
            throws IOException {
        String sql = source().replaceAll("\\s+", " ").toLowerCase();
        for (String table : new String[]{
                "production_fqc_replenishment_cycles",
                "production_fqc_replenishment_attempts",
                "production_fqc_replenishment_supply_gaps",
                "production_fqc_replenishment_draw_links",
                "production_fqc_replenishment_ready_events",
                "production_fqc_replenishment_ready_reversals",
                "production_fqc_replenishment_cycle_cancellations"}) {
            assertThat(sql)
                    .contains("before update or delete on " + table)
                    .contains("after insert or update or delete on " + table)
                    .contains("create trigger trg_audit_" + table);
        }
    }

    private static String source() throws IOException {
        Path direct = Path.of("src/main/resources/db/migration/"
                + "V415__production_fqc_replenishment_material_cycle.sql");
        Path path = Files.exists(direct)
                ? direct : Path.of("server").resolve(direct);
        return Files.readString(path, StandardCharsets.UTF_8);
    }
}
