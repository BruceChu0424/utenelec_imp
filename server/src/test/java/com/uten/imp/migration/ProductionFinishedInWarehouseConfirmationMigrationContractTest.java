package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionFinishedInWarehouseConfirmationMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V338__production_finished_in_warehouse_confirmation.sql");

    @Test
    void migrationAddsReportedQuantityAndExactDailyReportItemProvenance()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("add column reported_qty numeric(18,4)")
                .contains("add column deleted_at timestamptz")
                .contains("add column source_daily_report_item_id uuid")
                .contains("references production_daily_report_items(id) on delete restrict")
                .contains("set reported_qty = qty")
                .contains("where bill_type = 'finished_in'")
                .contains("report_item.report_id = document.source_daily_report_id")
                .contains("report_item.plan_item_id is not distinct from item.upstream_item_id")
                .contains("report_item.execution_segment_id is not distinct from item.execution_segment_id")
                .contains("report_item.execution_segment_sales_allocation_id is not distinct from item.execution_segment_sales_allocation_id")
                .contains("and 1 = ( select count(*)")
                .contains("set constraints all immediate")
                .contains("stock_document_item_reported_qty_chk")
                .contains("idx_stock_document_item_source_daily_report_item");
    }

    @Test
    void confirmationLedgerIsAppendOnlyAndConservesAcceptedPlusResidual()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("create table production_finished_in_confirmations")
                .contains("stock_document_id uuid not null unique")
                .contains("decision in ('accepted', 'partial', 'rejected', 'legacy_approved')")
                .contains("decision = 'partial' and residual_stock_document_id is not null")
                .contains("decision = 'rejected' and residual_stock_document_id is null")
                .contains("create table production_finished_in_confirmation_items")
                .contains("stock_document_item_id uuid not null unique")
                .contains("accepted_qty >= 0")
                .contains("residual_qty >= 0")
                .contains("accepted_qty + residual_qty = reported_qty")
                .contains("residual_qty > 0 and residual_stock_document_item_id is not null")
                .contains("production finished_in confirmation is append-only")
                .contains("trg_guard_production_finished_in_confirmation")
                .contains("trg_guard_production_finished_in_confirmation_item")
                .contains("trg_audit_production_finished_in_confirmations")
                .contains("trg_audit_production_finished_in_confirmation_items")
                .contains("create table production_finished_in_confirmation_reversals")
                .contains("create table production_finished_in_confirmation_reversal_items")
                .contains("confirmation_id uuid not null unique")
                .contains("replacement_stock_document_id uuid not null unique")
                .contains("confirmation_item_id uuid not null unique")
                .contains("trg_guard_production_finished_in_confirmation_reversal")
                .contains("trg_guard_production_finished_in_confirmation_reversal_item");
    }

    @Test
    void deferredValidationProvesEveryLineResidualAndSourcePlan()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("warehouse confirmation must cover every source line")
                .contains("source_line_count <> confirmation_line_count")
                .contains("source_item.reported_qty is distinct from confirmed.reported_qty")
                .contains("source_item.qty is distinct from confirmed.accepted_qty")
                .contains("source_report_item.id is null")
                .contains("residual_item.source_daily_report_item_id is distinct from source_item.source_daily_report_item_id")
                .contains("residual finished_in must keep the source plan")
                .contains("rejected confirmation must preserve all quantity for report correction")
                .contains("deferrable initially deferred")
                .contains("trg_validate_production_finished_in_confirmation")
                .contains("trg_validate_production_finished_in_confirmation_items")
                .contains("confirmed finished_in reversal event is missing")
                .contains("finished_in reversal must replace every accepted slice")
                .contains("finished_in reversal replacement provenance is invalid")
                .contains("trg_validate_finished_in_confirmation_source_state");
    }

    @Test
    void narrowGucLaneAllowsOnlyProportionalDraftQuantityShrink()
            throws Exception {
        String sql = compact();
        String guard = sql.substring(sql.indexOf(
                "create or replace function fn_guard_production_linked_stock_document_item"));

        assertThat(guard)
                .contains("current_setting( 'app.production_finished_in_confirm_doc_id', true) = v_document_id::text")
                .contains("v_document.doc_type = 'finished_in'")
                .contains("v_document.status = 0")
                .contains("old.qty > 0")
                .contains("new.qty > 0")
                .contains("new.qty <= new.reported_qty")
                .contains("new.base_qty is not distinct from round(new.qty * new.unit_rate, 4)")
                .contains("'qty','base_qty','reported_qty','amount_original','amount_local', 'weight','gift_qty','updated_at','updated_by'")
                .contains("new.goods_id is distinct from old.goods_id")
                .contains("new.execution_segment_id is distinct from old.execution_segment_id")
                .contains("new.source_daily_report_item_id is distinct from old.source_daily_report_item_id")
                .contains("production_linked_stock_document_item_update_guard");
    }

    @Test
    void historicalApprovedProductionReceiptsReceiveLegacyConfirmationOnly()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("'legacy_approved'")
                .contains("'legacy-finished-in:' || document.id")
                .contains("document.doc_type = 'finished_in'")
                .contains("document.status = 1")
                .contains("fn_is_production_linked_stock_document(document.id)")
                .contains("coalesce(item.reported_qty, item.qty), item.qty, 0")
                .contains("on conflict (stock_document_id) do nothing")
                .contains("on conflict (stock_document_item_id) do nothing");
    }

    private static String compact() throws Exception {
        return Files.readString(MIGRATION, StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}
