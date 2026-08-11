package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.assertTrue;

class ProductionExecutionSegmentOperationsMigrationTest {

    @Test
    void migrationContainsExactReportingInboundAndCompletionGates()
            throws IOException {
        String sql;
        try (var stream = getClass().getResourceAsStream(
                "/db/migration/V156__production_execution_segment_operations.sql")) {
            if (stream == null) {
                throw new IOException("V156 migration resource is missing");
            }
            sql = new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        }

        assertTrue(sql.contains(
                "production_daily_report_items.execution_segment_id"));
        assertTrue(sql.contains(
                "stock_document_items.execution_segment_id"));
        assertTrue(sql.contains(
                "stock_document_execution_segment_quantity_guard"));
        assertTrue(sql.contains(
                "finished-in requires an in-progress execution segment"));
        assertTrue(sql.contains(
                "v_inbound = v_planned AND v_clear"));
        assertTrue(sql.contains(
                "stock_document_completed_segment_reverse_guard"));
    }
}
