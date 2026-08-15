package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionOrderSnapshotApprovalGuardMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V283__production_order_snapshot_approval_lock.sql");

    @Test
    void v283UsesAnImmediateDraftProofAndKeepsTheSourceGuardDeferred()
            throws IOException {
        String sql = compact(Files.readString(MIGRATION));

        assertThat(sql)
                .contains("create or replace function "
                        + "fn_is_production_order_snapshot_approval_lock")
                .contains("p_old ->> 'goods_snapshot_locked_at' is null")
                .contains("p_new ->> 'goods_snapshot_locked_at' is not null")
                .contains("header.status = 0")
                .contains("coalesce(header.is_deleted, false) = false")
                .contains("request_item_at_approval")
                .contains("application_item_at_approval")
                .contains("master_at_approval")
                .contains("upstream.id = new.request_item_id")
                .contains("upstream.id = new.application_item_id")
                .contains("upstream.goods_id = new.goods_id")
                .contains("upstream.goods_code_snapshot is not distinct from "
                        + "new.goods_code_snapshot")
                .contains("upstream.goods_name_snapshot is not distinct from "
                        + "new.goods_name_snapshot")
                .contains("master.id = new.goods_id")
                .contains("master.code is not distinct from new.goods_code_snapshot")
                .contains("master.name is not distinct from new.goods_name_snapshot")
                .contains("and v_provenance_is_exact")
                .contains("for share")
                .contains("before update of goods_code_snapshot, "
                        + "goods_name_snapshot, goods_snapshot_source, "
                        + "goods_snapshot_locked_at on purchase_order_items")
                .contains("before update of goods_code_snapshot, "
                        + "goods_name_snapshot, goods_snapshot_source, "
                        + "goods_snapshot_locked_at on subcontract_order_items")
                .contains("deferrable initially deferred")
                .contains("fn_guard_production_supply_source_item()");
    }

    @Test
    void v283WhitelistsOnlyTheFourSnapshotColumnsAndPreservesBothConstraints()
            throws IOException {
        String sql = compact(Files.readString(MIGRATION));

        assertThat(sql)
                .contains("p_old - array[ 'goods_code_snapshot', "
                        + "'goods_name_snapshot', 'goods_snapshot_source', "
                        + "'goods_snapshot_locked_at' ]::text[]")
                .contains("is not distinct from ( p_new - array[")
                .contains("production_purchase_order_item_supply_guard")
                .contains("production_subcontract_order_item_supply_guard")
                .doesNotContain("set constraints")
                .doesNotContain("disable trigger")
                .doesNotContain("session_replication_role");
    }

    @Test
    void approvalServicesWriteOnlyTheSnapshotQuartetWithAFirstLockPredicate()
            throws IOException {
        String purchase = compact(Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/purchase/order/"
                        + "PurchaseOrderService.java")));
        String subcontract = compact(Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/subcontract/order/"
                        + "SubcontractOrderService.java")));

        assertThat(purchase).contains(
                "update purchase_order_items set goods_code_snapshot = :code, "
                        + "goods_name_snapshot = :name, goods_snapshot_source = :source, "
                        + "goods_snapshot_locked_at = :lockedat where id = :id "
                        + "and goods_snapshot_locked_at is null");
        assertThat(subcontract).contains(
                "update subcontract_order_items set goods_code_snapshot = :code, "
                        + "goods_name_snapshot = :name, goods_snapshot_source = :source, "
                        + "goods_snapshot_locked_at = :lockedat where id = :id "
                        + "and goods_snapshot_locked_at is null");
    }

    private static String compact(String value) {
        return value.toLowerCase(Locale.ROOT).replaceAll("\\s+", " ").trim();
    }
}
