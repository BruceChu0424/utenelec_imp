package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SubcontractTargetOutboundPreparationMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V436__subcontract_target_outbound_preparation.sql");
    private static final Path RESET = Path.of("ops/reset_business_data.sql");

    @Test
    void v436KeepsExistingV304RowsExecutableAsLegacy() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("add column flow_mode text not null "
                        + "default 'legacy_bom_component'")
                .contains("add column preparation_status text not null "
                        + "default 'legacy_ready'")
                .contains("update subcontract_material_plan_items "
                        + "set prepared_qty = planned_qty "
                        + "where flow_mode = 'legacy_bom_component'")
                .contains("'legacy_bom_component', 'direct_outbound', "
                        + "'make_then_outbound'")
                .doesNotContain("delete from subcontract_material_plan_items")
                .doesNotContain("update subcontract_material_issue_items set")
                .doesNotContain("update subcontract_receipt_items set");
    }

    @Test
    void preparationSourceUsesCompositeIdentityAndDeferredLineageGuard()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("foreign key (preparation_analysis_id, "
                        + "preparation_analysis_item_id) references "
                        + "production_material_analysis_items(analysis_id, id)")
                .contains("deferrable initially deferred")
                .contains("analysis_item.source_type = "
                        + "'subcontract_preparation'")
                .contains("analysis_item.source_ref = 'sc-prep:' "
                        + "|| plan_item.order_item_id::text")
                .contains("analysis_item.goods_id = plan_item.goods_id")
                .contains("analysis_item.color_id is not distinct from "
                        + "plan_item.color_id")
                .contains("analysis_item.unit_id = plan_item.unit_id")
                .contains("analysis_item.requested_qty = plan_item.planned_qty")
                .contains("trg_subcontract_preparation_source_guard")
                .contains("trg_subcontract_preparation_analysis_source_guard "
                        + "after insert or update or delete on "
                        + "production_material_analysis_items "
                        + "deferrable initially deferred")
                .contains("subcontract_preparation analysis item lacks "
                        + "a real subcontract task");
    }

    @Test
    void bomSnapshotConstraintIsFutureWriteEnforcedWithoutLegacyScan()
            throws Exception {
        String sql = compact();
        String definition = "add constraint "
                + "subcontract_material_plan_item_bom_snapshot_chk check";

        assertThat(sql)
                .contains(definition)
                .contains("flow_mode = 'legacy_bom_component' "
                        + "and bom_has_children_snapshot is null")
                .contains("flow_mode = 'direct_outbound' "
                        + "and bom_has_children_snapshot = false")
                .contains("flow_mode = 'make_then_outbound' "
                        + "and bom_has_children_snapshot = true")
                .contains("preparation_bom_fingerprint ~ '^[0-9a-f]{64}$'")
                .contains(") not valid;");
        assertThat(occurrences(sql, definition))
                .as("the named PostgreSQL constraint must be added once")
                .isEqualTo(1);
    }

    @Test
    void outboundReservationOwnerIsExplicitAndSupplyBacked() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("'preplan_analysis', 'subcontract_outbound'")
                .contains("owner_type = 'subcontract_outbound' "
                        + "and purpose = 'subcontract_outbound'")
                .contains("order_item_id is null and demand_id is null")
                .contains("owner_id is not null and warehouse_id is not null")
                .contains("supply_type in ('stock_balance', "
                        + "'production_finished_in')")
                .contains("supply_id is not null "
                        + "and idempotency_key is not null")
                .contains("idx_stock_reservation_subcontract_outbound_owner")
                .contains("idx_stock_reservation_subcontract_outbound_supply");
    }

    @Test
    void planningCommandsAreReplayableAppendOnlyAndAudited() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("create table subcontract_outbound_preparation_commands")
                .contains("unique (plan_item_id, operation, idempotency_key)")
                .contains("resulting_version = expected_version + 1")
                .contains("subcontract preparation commands are append-only")
                .contains("before update or delete on "
                        + "subcontract_outbound_preparation_commands")
                .contains("trg_audit_subcontract_outbound_preparation_commands")
                .contains("create table "
                        + "subcontract_outbound_issue_reservation_allocations")
                .contains("unique (issue_item_id, reservation_id)")
                .contains("unique (idempotency_key)")
                .contains("trg_audit_subcontract_outbound_issue_reservation_allocations");
    }

    @Test
    void allocationAndReservationFactsAreDeferredAndBidirectionallyExact()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("reservation.owner_id <> allocation.plan_item_id")
                .contains("reservation.warehouse_id is distinct from "
                        + "issue.warehouse_id")
                .contains("reservation.goods_id is distinct from "
                        + "issue_item.goods_id")
                .contains("reservation.color_id is distinct from "
                        + "issue_item.color_id")
                .contains("approved subcontract target issue lacks exact "
                        + "reservation coverage")
                .contains("subcontract outbound reservation lacks exact "
                        + "issue allocation")
                .contains("trg_subcontract_outbound_allocation_guard "
                        + "after insert or update or delete on "
                        + "subcontract_outbound_issue_reservation_allocations "
                        + "deferrable initially deferred")
                .contains("trg_subcontract_outbound_reservation_guard "
                        + "after insert or update or delete on "
                        + "stock_reservations deferrable initially deferred")
                .contains("trg_subcontract_outbound_issue_header_allocation_guard "
                        + "after insert or update or delete on "
                        + "subcontract_material_issues "
                        + "deferrable initially deferred");
    }

    @Test
    void finishedInReservationKeepsExactSourceDimensionsUnderReverseWrites()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("fn_assert_subcontract_preparation_finished_source")
                .contains("reservation.supply_type = 'production_finished_in'")
                .contains("stock_item.id = reservation.supply_id")
                .contains("stock_item.doc_id = reservation.source_doc_id")
                .contains("production_plan.status = 1")
                .contains("analysis_link.allocation_status = 'approved'")
                .contains("reservation.goods_id = stock_item.goods_id")
                .contains("reservation.goods_id = production_item.goods_id")
                .contains("reservation.goods_id = plan_item.goods_id")
                .contains("stock_item.unit_id = production_item.unit_id")
                .contains("stock_item.unit_id = plan_item.unit_id")
                .contains("coalesce(stock_item.unit_rate, 1) = 1")
                .contains("coalesce(production_item.unit_rate, 1) = 1")
                .contains("production_plan.material_analysis_id = "
                        + "plan_item.preparation_analysis_id")
                .contains("subcontract preparation finished_in reservation "
                        + "lineage is inconsistent")
                .contains("trg_subcontract_prep_finished_stock_item_guard")
                .contains("trg_subcontract_prep_finished_stock_doc_guard")
                .contains("trg_subcontract_prep_finished_production_item_guard")
                .contains("trg_subcontract_prep_finished_production_plan_guard")
                .contains("trg_subcontract_prep_finished_analysis_link_guard")
                .contains("trg_subcontract_prep_finished_plan_item_guard")
                .contains("then nullif(to_jsonb(old) ->> 'plan_id', '')::uuid "
                        + "else old.id end")
                .contains("then nullif(to_jsonb(new) ->> 'plan_id', '')::uuid "
                        + "else new.id end")
                .doesNotContain("then old.plan_id else old.id end")
                .doesNotContain("then new.plan_id else new.id end");
    }

    @Test
    void receiptAndIssueHeadersBothEnforceOutboundFirstConservation()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("if v_received > v_issued then")
                .contains("subcontract target receipt exceeds approved "
                        + "target-item outbound")
                .contains("if v_consumed <> v_received then")
                .contains("subcontract target receipt lacks exact "
                        + "supplier-held consumption")
                .contains("trg_subcontract_target_receipt_header_guard "
                        + "after insert or update or delete on "
                        + "subcontract_receipts deferrable initially deferred")
                .contains("trg_subcontract_target_receipt_item_guard "
                        + "after insert or update or delete on "
                        + "subcontract_receipt_items deferrable initially deferred")
                .contains("trg_subcontract_target_issue_consumption_guard "
                        + "after insert or update or delete on "
                        + "subcontract_material_issue_items "
                        + "deferrable initially deferred")
                .contains("trg_subcontract_target_issue_header_guard "
                        + "after insert or update or delete on "
                        + "subcontract_material_issues "
                        + "deferrable initially deferred");
    }

    @Test
    void businessResetOwnsBothNewAppendOnlyTables() throws Exception {
        String reset = Files.readString(RESET, StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();

        assertThat(reset)
                .contains("('subcontract_outbound_issue_reservation_allocations', "
                        + "'clear')")
                .contains("('subcontract_outbound_preparation_commands', 'clear')");
    }

    private static String compact() throws Exception {
        return Files.readString(MIGRATION, StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
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
