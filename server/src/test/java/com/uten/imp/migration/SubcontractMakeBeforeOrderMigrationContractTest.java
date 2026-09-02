package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V458 静态契约：有子层级委外件「先自制、后通知委外」与分批通知。
 * 锁定：分析来源类型扩展、任务/批次账本、PREPARED_OUTBOUND 行形状、
 * SUBCONTRACT_PREPARE_TASK 预留 owner、批次守恒守卫与审计/reset 注册。
 */
class SubcontractMakeBeforeOrderMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V458__subcontract_make_before_order.sql");
    private static final Path RESET = Path.of("ops/reset_business_data.sql");

    private static String compact(Path path) throws Exception {
        return Files.readString(path, StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }

    private static String migration() throws Exception {
        return compact(MIGRATION);
    }

    private static long occurrences(String sql, String needle) {
        long count = 0;
        int index = 0;
        while ((index = sql.indexOf(needle, index)) >= 0) {
            count++;
            index += needle.length();
        }
        return count;
    }

    @Test
    void analysisSourceAndActionTypesExtendWithoutRewritingHistory()
            throws Exception {
        String sql = migration();

        assertThat(sql)
                .contains("'stock', 'other', 'make_component', "
                        + "'subcontract_make'")
                .contains("source_type in ('make_component', "
                        + "'subcontract_make')")
                .contains("uq_production_material_analysis_make_component_parent")
                .contains("fn_validate_make_component_source_dimension")
                .contains("'purchase_request', 'subcontract_application',")
                .contains("'preplan_make_task', 'subcontract_make_task'")
                .doesNotContain("delete from production_material_analysis_items")
                .doesNotContain("update production_material_analyses set");
        assertThat(occurrences(sql, "drop constraint "
                + "production_material_analysis_item_source_type_chk"))
                .isEqualTo(1);
    }

    @Test
    void taskLedgerAndBatchesAreConservationGuarded() throws Exception {
        String sql = migration();

        assertThat(sql)
                .contains("create table preplan_subcontract_make_tasks")
                .contains("notified_qty <= produced_qty")
                .contains("notified_qty <= required_qty")
                .contains("(status = 'cancelled' and produced_qty = 0 "
                        + "and notified_qty = 0)")
                .contains("uq_preplan_subcontract_make_task_material")
                .contains("create table "
                        + "preplan_subcontract_make_task_batches")
                .contains("unique (task_id, idempotency_key)")
                .contains("unique (application_item_id)")
                .contains("fn_assert_subcontract_make_task_batches")
                .contains("notified qty lacks exact batch coverage")
                .contains("trg_subcontract_make_task_batch_guard "
                        + "after insert or update or delete on "
                        + "preplan_subcontract_make_task_batches "
                        + "deferrable initially deferred")
                .contains("trg_subcontract_make_task_qty_guard "
                        + "after update of notified_qty, status on "
                        + "preplan_subcontract_make_tasks "
                        + "deferrable initially deferred");
    }

    @Test
    void preparedOutboundFlowKeepsStrictShapeAndLineage() throws Exception {
        String sql = migration();

        assertThat(sql)
                .contains("'legacy_bom_component', 'direct_outbound',")
                .contains("'make_then_outbound', 'prepared_outbound'")
                .contains("flow_mode = 'prepared_outbound'")
                .contains("prepared_qty = planned_qty")
                .contains("subcontract prepared-outbound lineage "
                        + "is inconsistent")
                .contains("batch.notify_qty >= plan_item.planned_qty")
                .contains("analysis_item.requested_qty >= "
                        + "plan_item.planned_qty");
        assertThat(occurrences(sql, "drop constraint "
                + "subcontract_material_plan_item_flow_mode_chk")).isEqualTo(1);
        // 直下单 MAKE_THEN_OUTBOUND 的分批释放是应用层门禁放宽，
        // 数据库形状本就允许 prepared < planned，V458 不改写 V436 约束语义。
        assertThat(sql)
                .doesNotContain("update subcontract_material_plan_items "
                        + "set preparation_status");
    }

    @Test
    void prepareTaskReservationOwnerIsSupplyBackedAndShapeChecked()
            throws Exception {
        String sql = migration();

        assertThat(sql)
                .contains("'subcontract_prepare_task'")
                .contains("owner_type = 'subcontract_prepare_task' "
                        + "and purpose = 'subcontract_prepare_task'")
                .contains("supply_type = 'production_finished_in'")
                .contains("supply_id is not null "
                        + "and idempotency_key is not null")
                .contains("idx_stock_reservation_subcontract_prepare_task_owner");
        assertThat(occurrences(sql, "drop constraint "
                + "stock_reservations_owner_shape_chk")).isEqualTo(1);
    }

    @Test
    void existingGuardsAcceptPreparedOutboundAndNewTablesAreAudited()
            throws Exception {
        String sql = migration();

        assertThat(sql)
                .contains("'direct_outbound','make_then_outbound',"
                        + "'prepared_outbound'")
                .contains("plan_item.flow_mode in ( "
                        + "'make_then_outbound', 'prepared_outbound')")
                .contains("trg_audit_preplan_subcontract_make_tasks")
                .contains("trg_audit_preplan_subcontract_make_task_batches");
    }

    @Test
    void resetRegistersBothLedgerTablesAsClearAndCatalogAcceptsV458()
            throws Exception {
        String reset = compact(RESET);

        assertThat(reset)
                .contains("('preplan_subcontract_make_task_batches', 'clear')")
                .contains("('preplan_subcontract_make_tasks', 'clear')")
                .contains("(458, 420)");
    }
}
