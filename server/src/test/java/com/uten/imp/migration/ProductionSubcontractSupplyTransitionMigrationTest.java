package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.assertTrue;

class ProductionSubcontractSupplyTransitionMigrationTest {

    @Test
    void migrationKeepsSubcontractSupplyExactReversibleAndActionable()
            throws IOException {
        String sql;
        try (var stream = getClass().getResourceAsStream(
                "/db/migration/V158__production_subcontract_supply_transition.sql")) {
            if (stream == null) {
                throw new IOException("V158 migration resource is missing");
            }
            sql = new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        }

        assertTrue(sql.contains(
                "production_material_subcontract_peg_transfers"));
        assertTrue(sql.contains(
                "production_material_subcontract_receipt_allocations"));
        assertTrue(sql.contains(
                "production_subcontract_transfer_provenance_guard"));
        assertTrue(sql.contains(
                "production_subcontract_receipt_provenance_guard"));
        assertTrue(sql.contains(
                "production_subcontract_order_reversal_guard"));
        assertTrue(sql.contains(
                "production_subcontract_receipt_reversal_guard"));
        assertTrue(sql.contains(
                "'SUBCONTRACT_APPLICATION'"));
        assertTrue(sql.contains(
                "'SUBCONTRACT_ORDER'"));
        assertTrue(sql.contains(
                "'SUBCONTRACT_RECEIPT'"));
        assertTrue(sql.contains(
                "'APPLICATION_PENDING_APPROVAL'"));
        assertTrue(sql.contains(
                "'ORDER_PENDING_APPROVAL'"));
        assertTrue(sql.contains(
                "'RECEIPT_PENDING_APPROVAL'"));
        assertTrue(sql.contains(
                "'WAITING_RETURN'"));
    }
}
