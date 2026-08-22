package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class PreplanMakeEntitlementDelegationMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V337__preplan_make_entitlement_delegation.sql");

    @Test
    void migrationAddsAppendOnlyAuditedMakeDelegationPairs()
            throws Exception {
        String sql = compact();
        assertThat(sql)
                .contains("create table preplan_make_entitlement_delegations")
                .contains("preplan make entitlement delegations are append-only")
                .contains("trg_audit_preplan_make_entitlement_delegations")
                .contains("'make_delegate_out'")
                .contains("'make_delegate_in'")
                .contains("deferrable initially deferred")
                .contains("make delegation out/in totals must equal header quantity")
                .contains("uq_preplan_make_delegate_out_group")
                .contains("uq_preplan_make_delegate_in_group");
        String lotView = sql.substring(
                sql.indexOf("create or replace view "
                        + "v_preplan_stock_entitlement_lot_balance"),
                sql.indexOf("create or replace view "
                        + "v_preplan_stock_entitlement_beneficiary_balance"));
        assertThat(lotView)
                .contains("'make_delegate_out'")
                .contains("'make_delegate_in'");
    }

    @Test
    void migrationGuardsStableParentChildBomAndPhysicalDimensions()
            throws Exception {
        String sql = compact();
        assertThat(sql)
                .contains("child_item.parent_analysis_material_id "
                        + "is distinct from parent_material.id")
                .contains("source_material.parent_node_key "
                        + "is distinct from parent_material.node_key")
                .contains("target_material.bom_item_id "
                        + "is distinct from source_material.bom_item_id")
                .contains("target_material.goods_id "
                        + "is distinct from source_material.goods_id")
                .contains("target_material.color_id "
                        + "is distinct from source_material.color_id")
                .contains("target_material.unit_id "
                        + "is distinct from source_material.unit_id")
                .contains("reservation.warehouse_id "
                        + "is distinct from analysis.warehouse_id")
                .contains("target_effective + new.qty "
                        + "> target_material.required_qty")
                .contains("new.qty > source_remaining");
    }

    @Test
    void backfillIsProvableStableAndIdempotent() throws Exception {
        String sql = compact();
        String backfill = sql.substring(sql.indexOf("do $$"));
        assertThat(backfill)
                .contains("chosen.action_count = 1")
                .contains("child.submitted_qty = 0")
                .contains("child.approved_qty = 0")
                .contains("balance.source_exact_peg_id is not null")
                .contains("positive.reallocation_id is null")
                .contains("target_material.required_qty > 0")
                .contains("link.allocation_status in ('submitted', 'approved')")
                .contains("formalize.event_type = 'formalize'")
                .contains("order by balance.created_at, "
                        + "balance.entitlement_event_id")
                .contains("make-delegate-backfill:")
                .contains("on conflict (idempotency_key) do nothing")
                .contains("v_preplan_make_entitlement_delegation_gaps")
                .contains("'child_already_planned'")
                .contains("'ambiguous_make_action'")
                .contains("'formalized_entitlement'")
                .doesNotContain("update preplan_stock_entitlement_events")
                .doesNotContain("delete from preplan_stock_entitlement_events");
    }

    private static String compact() throws Exception {
        return Files.readString(MIGRATION, StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}
