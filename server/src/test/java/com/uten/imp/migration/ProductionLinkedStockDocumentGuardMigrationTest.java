package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.assertTrue;

class ProductionLinkedStockDocumentGuardMigrationTest {

    @Test
    void v164ClosesGenericCrudAndKeepsExactReportCleanupLane()
            throws IOException {
        String sql;
        try (var stream = getClass().getResourceAsStream(
                "/db/migration/"
                        + "V164__production_linked_stock_document_guards.sql")) {
            if (stream == null) {
                throw new IOException("V164 migration resource is missing");
            }
            sql = new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        }

        assertTrue(sql.contains(
                "fn_is_production_linked_stock_document"));
        assertTrue(sql.contains(
                "production_planning_package_documents"));
        assertTrue(sql.contains("plan_draw_links"));
        assertTrue(sql.contains("execution_segment_id IS NOT NULL"));
        assertTrue(sql.contains(
                "execution_segment_sales_allocation_id IS NOT NULL"));
        assertTrue(sql.contains(
                "production_linked_stock_document_update_guard"));
        assertTrue(sql.contains(
                "production_linked_stock_document_delete_guard"));
        assertTrue(sql.contains(
                "production_linked_stock_document_item_update_guard"));
        assertTrue(sql.contains(
                "app.production_report_reverse_doc_id"));
        assertTrue(sql.contains(
                "fn_is_production_report_cleanup_authorized"));
    }
}
