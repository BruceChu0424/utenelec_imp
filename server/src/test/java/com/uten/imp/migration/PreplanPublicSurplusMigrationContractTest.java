package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class PreplanPublicSurplusMigrationContractTest {

    private static String migration() throws Exception {
        Path direct = Path.of("src", "main", "resources", "db", "migration",
                "V472__preplan_public_surplus_and_shared_future_claims.sql");
        Path fallback = Path.of("server").resolve(direct);
        return Files.readString(Files.exists(direct) ? direct : fallback,
                StandardCharsets.UTF_8);
    }

    @Test
    void separatesDemandPublicSurplusAndClaimIdentity() throws Exception {
        String sql = migration();
        assertThat(sql)
                .contains("ADD COLUMN public_surplus_qty")
                .contains("ADD COLUMN public_surplus_external_item_id")
                .contains("ADD COLUMN claim_source_action_id")
                .contains("'SUPPLY', 'SHARED_FUTURE_CLAIM'")
                .contains("preplan_shared_future_claim_capacity_guard")
                .contains("CLAIM_SHARED_FUTURE")
                .contains("production_material_analysis:over_supply")
                .contains("production_material_analysis:claim_shared_future")
                .contains("production.material-analysis")
                .contains("department.code IN ('GM','SUB_PLAN')");
    }

    @Test
    void usesApprovedOpenCapacityAndKeepsNewAndLegacyShapesDistinct()
            throws Exception {
        String sql = migration();
        assertThat(sql)
                .contains("separate_public_item")
                .contains("LEAST(\n        source_action.public_surplus_qty")
                .contains("order_header.is_closed = FALSE")
                .contains("fn_preplan_public_surplus_open_qty")
                .contains("fn_preplan_allocation_effective_exact_qty");
        assertThat(sql).doesNotContain(
                "GREATEST(source_action.public_surplus_qty, approved_qty");
    }

    @Test
    void closesV463SourceIntegrityAndProtectsPublicLineage() throws Exception {
        String sql = migration();
        assertThat(sql)
                .contains("order item source allocation total must equal item quantity")
                .contains("DEFERRABLE INITIALLY DEFERRED")
                .contains("approved order item source allocation is immutable")
                .contains("OR action.public_surplus_external_item_id = p_supply_item_id")
                .contains("SUBCONTRACT_WITH_SUPPLY_BOM")
                .contains("APPROVED_OVERAGE_NOT_BACKFILLED");
    }
}
