package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.assertTrue;

class ProductionCompletionReverseMigrationTest {

    @Test
    void migrationKeepsDirectReverseClosedAndAddsAuditedReopenLane()
            throws IOException {
        String sql;
        try (var stream = getClass().getResourceAsStream(
                "/db/migration/V159__production_completion_reverse_workflow.sql")) {
            if (stream == null) {
                throw new IOException("V159 migration resource is missing");
            }
            sql = new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        }

        assertTrue(sql.contains("completion_reopened"));
        assertTrue(sql.contains("REOPEN_COMPLETION"));
        assertTrue(sql.contains(
                "app.production_completion_reopen_doc_id"));
        assertTrue(sql.contains(
                "fn_is_completion_reopen_authorized"));
        assertTrue(sql.contains(
                "OLD.status = 'COMPLETED'"));
        assertTrue(sql.contains(
                "NEW.status = 'IN_PROGRESS'"));
        assertTrue(sql.contains(
                "completion_reopened = FALSE"));
    }
}
