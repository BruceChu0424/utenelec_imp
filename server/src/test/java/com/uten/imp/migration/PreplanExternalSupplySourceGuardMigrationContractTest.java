package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class PreplanExternalSupplySourceGuardMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V250__preplan_external_supply_source_guards.sql");

    @Test
    void directPreplanSourcesKeepHistoryIncludingCancelledActions()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("idx_preplan_supply_action_external_document_history")
                .contains("idx_preplan_supply_allocation_external_item_history")
                .contains("preplan_supply_action_route_external_v250_chk")
                .contains("route = 'buy' and external_document_type = 'purchase_request'")
                .contains("route = 'subcontract' and external_document_type = "
                        + "'subcontract_application'")
                .contains("route = 'make' and external_document_type = 'preplan_make_task'")
                .contains("p_supply_type = 'purchase_request_item'")
                .contains("action.route = 'buy'")
                .contains("p_supply_type = 'subcontract_application_item'")
                .contains("action.route = 'subcontract'")
                .contains("allocation.external_item_id = p_supply_item_id")
                .contains("production_material_supply_pegs peg")
                .contains("peg.supply_type = p_supply_type")
                .contains("peg.supply_item_id = p_supply_item_id");
    }

    @Test
    void draftOrdersStayEditableUntilApprovalOrActionAdvancement()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("p_supply_type = 'purchase_order_item'")
                .contains("join purchase_orders order_header")
                .contains("p_supply_type = 'subcontract_order_item'")
                .contains("join subcontract_orders order_header")
                .contains("order_header.status <> 0 or action.status in ( "
                        + "'in_progress', 'done', 'cancelled')")
                .contains("fn_has_protected_preplan_order_context")
                .contains("v_old_order_id := old.order_id")
                .contains("v_new_order_id := new.order_id")
                .contains("v_old_upstream_item_id := old.request_item_id")
                .contains("v_new_upstream_item_id := new.request_item_id")
                .contains("v_old_upstream_item_id := old.application_item_id")
                .contains("v_new_upstream_item_id := new.application_item_id")
                .contains("not exists ( select 1 from purchase_orders "
                        + "order_header where order_header.id = p_order_id )")
                .contains("not exists ( select 1 from subcontract_orders "
                        + "order_header where order_header.id = p_order_id )");
    }

    @Test
    void provenanceRowsAndAdvancedActionsCannotBeDetachedToBypassGuard()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("trg_guard_preplan_supply_action_history")
                .contains("old.external_document_no is not null")
                .contains("new.external_document_type is not null or "
                        + "new.external_document_id is not null or "
                        + "new.external_document_no is not null")
                .contains("old.status <> 'open' or new.status <> 'created'")
                .contains("preplan_external_supply_action_handshake_guard")
                .contains("old.requested_qty is distinct from new.requested_qty")
                .contains("preplan_external_supply_action_identity_guard")
                .contains("preplan_external_supply_action_append_only_guard")
                .contains("preplan_external_supply_action_cancelled_guard")
                .contains("preplan_external_supply_action_status_guard")
                .contains("old.status in ('in_progress', 'done') and new.status = 'created'")
                .contains("trg_guard_preplan_supply_allocation_history")
                .contains("old.external_item_id is null")
                .contains("from preplan_supply_actions action where "
                        + "action.id = new.action_id for key share")
                .contains("v_action.status = 'created' and "
                        + "v_action.external_document_type = 'purchase_request'")
                .contains("item.request_id = v_action.external_document_id")
                .contains("v_action.external_document_type = 'subcontract_application'")
                .contains("item.application_id = v_action.external_document_id")
                .contains("v_action.external_document_type = 'preplan_make_task'")
                .contains("item.source_type = 'make_component'")
                .contains("preplan_external_supply_allocation_handshake_guard")
                .contains("preplan_external_supply_allocation_identity_guard")
                .contains("preplan_external_supply_allocation_append_only_guard");
    }

    @Test
    void sourceHeaderCancelIsAtomicButHistoricalRestartIsRejected()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("fn_has_preplan_external_document_history")
                .contains("not coalesce(p_live_only, false) or action.status <> 'cancelled'")
                .contains("v_document_type, old.id, false")
                .contains("production-linked source document cannot be reactivated")
                .contains("v_document_type, old.id, true")
                .contains("production-linked supply source must be released "
                        + "or cancelled before close")
                .doesNotContain("before update or delete on purchase_orders")
                .doesNotContain("before update or delete on subcontract_orders");
    }

    @Test
    void latestV194PlanItemAndFormalPegSemanticsRemainPresent()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("elsif tg_table_name = 'production_plan_items'")
                .contains("v_supply_type := 'production_plan_item'")
                .contains("production_plan_item_supply_guard")
                .contains("peg.supply_type = p_supply_type")
                .contains("peg.supply_item_id = p_supply_item_id");
    }

    private static String compact() throws Exception {
        return Files.readString(MIGRATION, StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}
