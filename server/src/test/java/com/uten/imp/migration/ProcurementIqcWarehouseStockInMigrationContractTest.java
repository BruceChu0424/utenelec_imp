package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

class ProcurementIqcWarehouseStockInMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V446__iqc_release_warehouse_stock_in.sql");

    @Test
    void v446SeparatesQualityReleaseFromImmutableWarehouseStockInFacts()
            throws Exception {
        assertThat(MIGRATION).isRegularFile();
        String sql = Files.readString(MIGRATION, StandardCharsets.UTF_8)
                .replaceAll("\\s+", " ")
                .toLowerCase(Locale.ROOT);

        assertThat(sql)
                .contains("add column warehouse_stocked_base_qty")
                .contains("add column legacy_stocked_base_qty")
                .contains("create or replace view v_preplan_buy_action_slice_progress")
                .contains("else inspection.warehouse_stocked_base_qty")
                .contains("inspection.received_base_qty - inspection.failed_base_qty - inspection.warehouse_stocked_base_qty")
                .contains("add column requires_warehouse_stock_in boolean not null default false")
                .contains("add column released_amount_local numeric(18,4)")
                .contains("released_weight_unit_id uuid")
                .contains("v446 cannot prove legacy iqc pass stock postings")
                .contains("create table procurement_iqc_stock_in_batches")
                .contains("create table procurement_iqc_stock_in_batch_items")
                .contains("unique (actor_user_id, idempotency_key)")
                .contains("request_hash char(64) not null")
                .contains("stock_movement_id uuid not null unique")
                .contains("expected_remaining_base_qty numeric(18,4) not null")
                .contains("weight_unit_id uuid references units(id) on delete restrict")
                .contains("v_event_confirmed > v_event.base_qty")
                .contains("v_event.requires_warehouse_stock_in is distinct from true")
                .contains("warehouse_stocked_base_qty is distinct from")
                .contains("legacy_stocked_base_qty + v_confirmed")
                .contains("iqc stock-in batch count does not match immutable items")
                .contains("iqc stock-in batch item count does not match immutable header")
                .contains("iqc pass release value must match the frozen receipt")
                .contains("procurement iqc warehouse stock-in facts are append-only")
                .contains("iqc warehouse stock-in movement is append-only")
                .contains("pre-v446 iqc automatic stock-in writer is not compatible")
                .doesNotContain("pass_event_id uuid not null unique")
                .doesNotContain("update stock_balances")
                .doesNotContain("flyway_schema_history");
    }

    @Test
    void v446RegistersAnExactNonCommercialWarehouseSurface() throws Exception {
        String sql = Files.readString(MIGRATION, StandardCharsets.UTF_8)
                .replaceAll("\\s+", " ")
                .toLowerCase(Locale.ROOT);

        assertThat(sql)
                .contains("warehouse_iqc_stock_in:view")
                .contains("warehouse_iqc_stock_in:confirm")
                .contains("warehouse.iqc-stock-in")
                .contains("不含金额、单价、成本或结算信息")
                .contains("'warehouse_inbound:view', 'warehouse_iqc_stock_in:view'")
                .contains("'warehouse_inbound:stock_in', 'warehouse_iqc_stock_in:confirm'")
                .contains("preserve the effective old authority graph exactly")
                .contains("insert into role_permissions")
                .contains("insert into department_permissions")
                .contains("insert into user_permission_overrides")
                .contains("insert into manager_permission_delegations")
                .contains("failed to preserve % old iqc-equivalent authorization")
                .contains("target iqc stock-in permission codes or surface already exist")
                .contains("source warehouse inbound permissions are missing, inactive or semantically incompatible")
                .contains("old_permission.active = true")
                .contains("source_surface.surface_key = delegation.surface_key")
                .contains("grantor_revoke.effect = 'revoke'")
                .contains("permission_surface_permissions")
                .doesNotContain("where department.code = 'dept_qa'")
                .doesNotContain("where department.code = 'sub_wh'")
                .doesNotContain("purchase_receipt:price:view")
                .doesNotContain("procurement_inspection:handle', 'warehouse.iqc-stock-in");
    }
}
