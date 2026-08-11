package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.assertTrue;

class ProductionSupplySourceGuardMigrationTest {

    @Test
    void v162ClosesSourceMutationAndSubcontractResurrectionGaps()
            throws IOException {
        String sql;
        try (var stream = getClass().getResourceAsStream(
                "/db/migration/"
                        + "V162__production_supply_source_and_"
                        + "subcontract_append_only_guards.sql")) {
            if (stream == null) {
                throw new IOException("V162 migration resource is missing");
            }
            sql = new String(
                    stream.readAllBytes(), StandardCharsets.UTF_8);
        }

        assertTrue(sql.contains(
                "production_purchase_request_item_supply_guard"));
        assertTrue(sql.contains(
                "production_subcontract_application_item_supply_guard"));
        assertTrue(sql.contains(
                "AFTER UPDATE OF status, is_deleted, warehouse_id, need_date"));
        assertTrue(sql.contains(
                "production_subcontract_transfer_append_only_guard"));
        assertTrue(sql.contains(
                "production_subcontract_receipt_append_only_guard"));
        assertTrue(sql.contains(
                "production_subcontract_transfer_lifecycle_guard"));
        assertTrue(sql.contains(
                "production_subcontract_receipt_lifecycle_guard"));
        assertTrue(sql.contains(
                "fn_assert_subcontract_peg_transfer_coverage"));
        assertTrue(sql.contains(
                "production_subcontract_peg_receipt_coverage_guard"));
        assertTrue(sql.contains(
                "trg_subcontract_peg_supply_conservation"));
        assertTrue(sql.contains(
                "DEFERRABLE INITIALLY DEFERRED"));
    }
}
