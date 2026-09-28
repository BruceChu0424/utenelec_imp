package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Locale;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V745 仓库重量账与单重学习(ADR-135)的迁移文本契约; 真库行为见 {@link WarehouseWeightLedgerMigrationPostgresTest}。
 *
 * <p>取代原 V435 对账视图的契约: 旧 v_stock_weight_reconciliation(按流水累加比对)已删除, 新视图按
 * 重量账链末行(ledger_seq)比对。
 */
class WarehouseWeightLedgerMigrationContractTest {

    private static final String FILE_SUFFIX = "__warehouse_weight_ledger_and_learning.sql";

    @Test
    void weightStaysKilogramNumeric184AndNeverTouchesTheWorkbenchViewChain() throws IOException {
        String sql = compact(source());
        assertThat(sql)
                .doesNotContain("alter column weight type")
                .doesNotContain("drop view v_stock_available")
                .doesNotContain("drop view v_fulfillment_workbench")
                .doesNotContain("cascade")
                .contains("create sequence stock_ledger_seq as bigint;")
                .contains("add column ledger_seq bigint not null default nextval('stock_ledger_seq')")
                .contains("add column weight_source varchar(10)")
                .contains("add column balance_weight_after numeric(18,4)")
                // 流水只追加且 IQC 关联行禁止 UPDATE: 来源成对约束只约束新行。
                .contains("check ( (weight is null) = (weight_source is null)) not valid;")
                .contains("create index idx_sm_goods_ledger on stock_movements (goods_id, transaction_date desc, ledger_seq desc);")
                .contains("create index idx_sm_src_item on stock_movements (source_doc_type, source_doc_id, source_item_id);")
                .contains("drop index idx_sm_src;")
                .contains("drop index idx_sm_goods_date;");
    }

    @Test
    void balancesNormalizeBeforeTheShapeCheckAndKeepTheCoverIndex() throws IOException {
        String sql = compact(source());
        int immediate = sql.indexOf("set constraints trg_stock_balance_managed_value immediate;");
        int normalize = sql.indexOf("update stock_balances balance");
        int deferred = sql.indexOf("set constraints trg_stock_balance_managed_value deferred;");
        int shape = sql.indexOf("add constraint stock_balances_weight_shape_chk");
        assertThat(immediate).isPositive();
        assertThat(normalize).isGreaterThan(immediate);
        assertThat(deferred).isGreaterThan(normalize);
        assertThat(shape).isGreaterThan(deferred);
        assertThat(sql)
                .contains("when candidate.qty = 0 then 0::numeric")
                .contains("when candidate.qty < 0 then null")
                .contains("when candidate.weight <= 0 then null")
                .contains("weight is null or (qty = 0 and weight = 0) or (qty > 0 and weight > 0)")
                .contains("include (warehouse_id, color_id, qty, weight, weight_estimated, last_movement_date)");
    }

    @Test
    void iqcValidatorsDropUnitTermsBeforeTheColumnsAndReaddTheLostChecks() throws IOException {
        String sql = compact(source());
        String passRelease = function(sql, "create or replace function fn_validate_procurement_iqc_pass_release_value()");
        String stockIn = function(sql, "create or replace function fn_validate_procurement_iqc_stock_in_item()");
        assertThat(passRelease).doesNotContain("weight_unit_id")
                .contains("or new.released_weight is distinct from v_expected_weight then");
        assertThat(stockIn).doesNotContain("weight_unit_id")
                .contains("and v_movement.weight_source in ('measured', 'slice')")
                .contains("and v_movement.weight is distinct from new.weight)")
                .contains("procurement_iqc_stock_in_item_identity_chk");
        int functions = sql.indexOf("create or replace function fn_validate_procurement_iqc_stock_in_item()");
        for (String drop : List.of(
                "alter table procurement_inspection_items drop column received_weight_unit_id;",
                "alter table procurement_inspection_events drop column released_weight_unit_id;",
                "alter table procurement_iqc_stock_in_batch_items drop column weight_unit_id;",
                "alter table stock_movements drop column actual_weight_unit_id;")) {
            assertThat(sql.indexOf(drop)).as(drop).isGreaterThan(functions);
        }
        assertThat(sql)
                .contains("add constraint procurement_inspection_events_stock_in_flag_chk check (")
                .contains("add constraint procurement_iqc_stock_in_item_weight_chk check ( weight is null or weight >= 0);");
    }

    @Test
    void retiresV442WithOneLiteralDropAndPatchesInstalledDefinitionsFailClosed() throws IOException {
        String sql = compact(source());
        assertThat(sql)
                .contains("drop view v_measurement_capture_profile_resolution;")
                .contains("drop table measurement_capture_decision_events, measurement_capture_evidence,"
                        + " measurement_capture_line_snapshots, measurement_capture_profiles,"
                        + " legacy_measurement_exceptions, legacy_measurement_profile_snapshots,"
                        + " legacy_measurement_source_registry;")
                .contains("drop function fn_reject_measurement_append_only_mutation();")
                .contains("pg_get_functiondef('business_data_reset()'::regprocedure)")
                .contains("pg_get_functiondef('fn_goods_quantity_reference_sources()'::regprocedure)")
                .contains("pg_get_functiondef('fn_guard_sales_shipment_picking_evidence()'::regprocedure)")
                .contains("pg_get_functiondef('fn_guard_production_linked_stock_document_item()'::regprocedure)")
                .contains("(''goods_weight_observations'', array[''goods_id''], ''true''),")
                .contains("''qty_from_weight'',''count_weight'',''book_weight''])")
                .contains("new.line_weights<>''{}''::jsonb");
    }

    @Test
    void newTablesCarryTheReviewedAuditPolicyAndThePermissionIsSeeded() throws IOException {
        String sql = compact(source());
        assertThat(sql)
                .contains("select fn_audit_track_table('goods_weight_profiles', 'full', 'data_change', false);")
                .contains("select fn_audit_track_table('goods_weight_observations', 'column_scoped', 'data_change', false,"
                        + " array['excluded_reason'], false);")
                .contains("select fn_audit_track_table('goods_weight_estimates', 'none', 'data_change', false);")
                .contains("select fn_audit_track_table('stock_weight_adjustments', 'none', 'data_change', false);")
                .contains("constraint goods_weight_observation_capture_key_uk unique (capture_key)")
                .contains("unique nulls not distinct (goods_id, supplier_id)")
                .contains("idempotency_key text unique")
                .contains("('stock:weight:manage', '称重设置与单重学习管理', '仓库管理', '库存', 203, 'configure',")
                .contains("('warehouse.stock-item', 'stock:weight:manage')")
                .contains("('basic.goods', 'stock:weight:manage')")
                .contains("source.code = 'stock_doc:edit'");
    }

    @Test
    void massUnitsAreAClosedCatalogueSeededByExactNamesOnly() throws IOException {
        String sql = compact(source());
        assertThat(sql)
                .contains("drop column canonical_unit_id")
                .contains("drop column to_canonical_factor")
                .contains("mass_unit_code in ('g', 'kg', 't', 'jin', 'lb', 'oz')")
                .contains("mass_unit_code is null or measurement_dimension = 'mass'")
                .contains("when 'lb' then 0.45359237")
                .contains("when 'oz' then 0.028349523125")
                .contains("on lower(btrim(unit_master.name, e' \\t' || chr(12288))) = mapping.unit_name")
                .contains("where unit_master.is_deleted = false")
                .doesNotContain("like '%kg%'");
    }

    private static String function(String compactSql, String header) {
        int start = compactSql.indexOf(header);
        assertThat(start).as(header).isGreaterThanOrEqualTo(0);
        int end = compactSql.indexOf("$function$;", start);
        assertThat(end).as(header + " body end").isGreaterThan(start);
        return compactSql.substring(start, end);
    }

    private static String source() throws IOException {
        Path direct = Path.of("src/main/resources/db/migration");
        Path directory = Files.exists(direct) ? direct : Path.of("server").resolve(direct);
        List<Path> matches;
        try (Stream<Path> files = Files.list(directory)) {
            matches = files.filter(path -> path.getFileName().toString().endsWith(FILE_SUFFIX)).toList();
        }
        assertThat(matches).as("exactly one warehouse weight ledger migration").hasSize(1);
        return Files.readString(matches.getFirst(), StandardCharsets.UTF_8);
    }

    private static String compact(String sql) {
        return sql.toLowerCase(Locale.ROOT).replaceAll("\\s+", " ").trim();
    }
}
