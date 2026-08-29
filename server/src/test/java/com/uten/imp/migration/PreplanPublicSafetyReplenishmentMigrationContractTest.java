package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class PreplanPublicSafetyReplenishmentMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V420__preplan_demand_and_public_safety_replenishment_split.sql");

    @Test
    void demandAndPublicSafetyAreSeparateConservedSlices() throws Exception {
        String sql = compact();

        assertThat(sql).contains("add column safety_replenishment_qty numeric(18,4)");
        assertThat(sql).contains("requested_qty + safety_replenishment_qty > 0");
        assertThat(sql).contains("safety_replenishment_qty = greatest(");
        assertThat(sql).contains("route = 'buy'");
        assertThat(sql).contains("safety_external_item_id uuid");
        assertThat(sql).contains(
                "foreign key (safety_external_item_id) references purchase_request_items(id) on delete restrict");
        assertThat(sql).contains(
                "allocation.external_item_id = new.safety_external_item_id");
        assertThat(sql).contains(
                "public safety replenishment item must be a separate matching purchase-request line");
        assertThat(sql).contains(
                "public safety replenishment must use the goods base unit");
        assertThat(sql).contains("coalesce(v_item.unit_rate, 1) <> 1");
    }

    @Test
    void progressProjectionSeparatesQualifiedFailedAndFutureQuantities()
            throws Exception {
        String sql = compact();

        assertThat(sql).contains("create view v_preplan_buy_action_slice_progress");
        assertThat(sql).contains("'demand'::text as slice_type");
        assertThat(sql).contains("'safety', action.safety_external_item_id");
        assertThat(sql).contains("when receipt.id is null then 0");
        assertThat(sql).contains("inspection.passed_base_qty");
        assertThat(sql).contains("inspection.failed_base_qty");
        assertThat(sql).contains("safety_future_qty");
        assertThat(sql).contains("coalesce(safety.pending_qty,0)");
    }

    @Test
    void v250ProtectionAlsoCoversTheSeparateSafetyLine() throws Exception {
        String sql = compact();

        assertThat(sql).contains("action.safety_external_item_id = p_supply_item_id");
        assertThat(sql).contains(
                "action.safety_external_item_id = order_item.request_item_id");
        assertThat(sql).contains(
                "action.safety_external_item_id = p_upstream_item_id");
    }

    @Test
    void forwardLifecycleRepairFreezesUnitsAndBlocksReverseAllocationHandshake()
            throws Exception {
        String sql = Files.readString(Path.of(
                        "src/main/resources/db/migration/"
                                + "V422__preplan_safety_action_lifecycle_unit_snapshot.sql"),
                        StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();

        assertThat(sql).contains("tg_op = 'insert' or v_first_external_handshake");
        assertThat(sql).contains("preplan_safety_item_demand_allocation_guard");
        assertThat(sql).contains(
                "action.safety_external_item_id = new.external_item_id");
        assertThat(sql).contains(
                "before insert or update of action_id, external_item_id");
    }

    private static String compact() throws Exception {
        return Files.readString(MIGRATION, StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}
