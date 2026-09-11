package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/** V547 品质检查单聚合层：只追加、同仓一致、审计、单号命名空间与清空策略（静态契约）。 */
class ProductionFqcInspectionSheetMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V547__production_fqc_inspection_sheets.sql");

    @Test
    void v547OwnsAppendOnlyAuditedSheetAggregateWithoutQuantityAuthority()
            throws Exception {
        String sql = Files.readString(MIGRATION).toLowerCase();

        assertThat(sql)
                .contains("('production_fqc_sheet', 'document', 'fqc',")
                .contains("create table production_fqc_inspection_sheets")
                .contains("create table production_fqc_inspection_sheet_items")
                .contains("sheet_no ~ '^fqc[0-9]{14}$'")
                .contains("source_kind in ('arrival_single', 'arrival_batch')")
                .contains("remark is null or length(remark) <= 500")
                .contains("production_fqc_inspection_sheet_batch_replay_uk")
                .contains("created_by, batch_idempotency_key, warehouse_id)")
                .contains("where batch_idempotency_key is not null")
                .contains("fn_reserve_business_document_identifier(\n        'production_fqc_sheet', 'sheet_no', '')")
                .contains("production_fqc_inspection_sheet_item_inspection_uk\n        unique (inspection_id)")
                .contains("production_fqc_inspection_sheet_item_registration_item_uk")
                .contains("unique (sheet_id, inspection_id)")
                .contains("unique (sheet_id, line_no)")
                .contains("inspection_row.status <> 'pending'")
                .contains("inspection_row.warehouse_id <> sheet_warehouse_id")
                .contains("registration_row.warehouse_id <> sheet_warehouse_id")
                .contains("registration_row.source_report_item_id\n            <> inspection_row.source_report_item_id")
                .contains("production fqc inspection sheet is append-only")
                .contains("production fqc inspection sheet item is append-only")
                .contains("deferrable initially deferred")
                .contains("fqc inspection sheet must contain at least one inspection")
                .contains("enable always trigger trg_guard_production_fqc_inspection_sheets")
                .contains("enable always trigger trg_guard_production_fqc_inspection_sheet_items")
                .contains("create trigger trg_audit_production_fqc_inspection_sheets")
                .contains("create trigger trg_audit_production_fqc_inspection_sheet_items")
                .contains("(''production_fqc_inspection_sheets'', ''clear'')")
                .contains("(''production_fqc_inspection_sheet_items'', ''clear'')")
                // 聚合层不改数量权威：不动 inspection 数量/状态列，不回填历史。
                .doesNotContain("update production_fqc_inspections")
                .doesNotContain("insert into production_fqc_inspection_sheets")
                .doesNotContain("insert into production_fqc_inspection_sheet_items")
                .doesNotContain("alter table production_fqc_inspections");
    }
}
