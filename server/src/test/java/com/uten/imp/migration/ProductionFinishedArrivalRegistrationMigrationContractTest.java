package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionFinishedArrivalRegistrationMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V430__production_finished_arrival_registration.sql");
    private static final Path PLACE_PREFERENCES_MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V431__warehouse_goods_place_preferences.sql");

    @Test
    void v430OwnsAppendOnlyAuditedRegistrationAndExactCoverage()
            throws Exception {
        String sql = Files.readString(MIGRATION).toLowerCase();

        assertThat(sql)
                .contains("create table production_finished_arrival_registrations")
                .contains("create table production_finished_arrival_registration_items")
                .contains("source_report_id         uuid not null unique")
                .contains("source_report_item_id    uuid not null unique")
                .contains("unique (\n        created_by, idempotency_key)")
                .contains("request_hash ~ '^[0-9a-f]{64}$'")
                .contains("length(place_snapshot) between 1 and 100")
                .contains("deferrable initially deferred")
                .contains("v_report_id uuid")
                .contains("must cover every report line exactly once")
                .contains("enable always trigger trg_guard_production_finished_arrival_registrations")
                .contains("enable always trigger trg_guard_production_finished_arrival_registration_items")
                .contains("create trigger trg_audit_production_finished_arrival_registrations")
                .contains("create trigger trg_audit_production_finished_arrival_registration_items")
                .doesNotContain("declare\n    report_id uuid")
                .doesNotContain("insert into production_finished_arrival_registrations(");
    }

    @Test
    void v430ForwardReplacesFqcGuardWithRegisteredWarehouseAuthority()
            throws Exception {
        String sql = Files.readString(MIGRATION).toLowerCase();

        assertThat(sql)
                .contains("create or replace function fn_guard_production_fqc_inspection()")
                .contains("join production_finished_arrival_registrations registration")
                .contains("join production_finished_arrival_registration_items registration_item")
                .contains("registration.warehouse_id as registered_warehouse_id")
                .contains("source_row.registered_warehouse_id <> new.warehouse_id")
                .doesNotContain("source_row.report_warehouse_id <> new.warehouse_id");
    }

    @Test
    void v431OwnsWarehouseGoodsColorPreferenceWithoutHistoricalBackfill()
            throws Exception {
        String sql = Files.readString(PLACE_PREFERENCES_MIGRATION)
                .toLowerCase();

        assertThat(sql)
                .contains("create table warehouse_goods_place_preferences")
                .contains("unique nulls not distinct (warehouse_id, goods_id, color_id)")
                .contains("place = btrim(place)")
                .contains("length(place) between 1 and 100")
                .contains("selection_count")
                .contains("version")
                .contains("source_registration_id")
                .contains("source_registered_at")
                .contains("last_selected_by")
                .contains("last_selected_at")
                .contains("references warehouses(id)")
                .contains("references goods(id)")
                .contains("references colors(id)")
                .contains("references employees(id)")
                .contains("references users(id)")
                .contains("references production_finished_arrival_registrations(id)")
                .contains("idx_warehouse_goods_place_preference_source")
                .contains("idx_warehouse_goods_place_preference_goods")
                .contains("trg_set_updated_at_warehouse_goods_place_preferences")
                .contains("trg_audit_warehouse_goods_place_preferences")
                .contains("execute function fn_audit()")
                .doesNotContain("update goods")
                .doesNotContain("insert into warehouse_goods_place_preferences select");
    }
}
