package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.assertTrue;

class ProductionPurchaseReceiptProvenanceMigrationTest {

    @Test
    void v163RevalidatesPurchaseReceiptProvenanceFromEverySource()
            throws IOException {
        String sql;
        try (var stream = getClass().getResourceAsStream(
                "/db/migration/"
                        + "V163__production_purchase_receipt_provenance.sql")) {
            if (stream == null) {
                throw new IOException("V163 migration resource is missing");
            }
            sql = new String(
                    stream.readAllBytes(), StandardCharsets.UTF_8);
        }

        assertTrue(sql.contains(
                "production_receipt_allocation_provenance_guard"));
        assertTrue(sql.contains(
                "production_purchase_receipt_item_capacity_guard"));
        assertTrue(sql.contains("receipt.status <> -1"));
        assertTrue(sql.contains("receipt_item.is_deleted = FALSE"));
        assertTrue(sql.contains("reservation.status = 0"));
        assertTrue(sql.contains(
                "package_document.execution_segment_id"));
        assertTrue(sql.contains(
                "idx_prod_purchase_receipt_alloc_order_peg_active"));
        assertTrue(sql.contains(
                "idx_prod_purchase_receipt_alloc_draw_item_active"));
        assertTrue(sql.contains(
                "ON production_material_demands"));
        assertTrue(sql.contains(
                "ON production_planning_package_document_items"));
        assertTrue(sql.contains("DEFERRABLE INITIALLY DEFERRED"));
    }
}
