package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class AuditLoginSessionCorrelationMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V428__audit_login_session_correlation.sql");

    @Test
    void v428BackfillsOnlyProvableTokenFamiliesAndKeepsHistoricalAuditUnknown()
            throws Exception {
        String sql = Files.readString(MIGRATION, StandardCharsets.UTF_8)
                .toLowerCase(java.util.Locale.ROOT);

        assertTrue(sql.contains("with recursive token_families"));
        assertTrue(sql.contains("predecessor.replaced_by = root.id"));
        assertTrue(sql.contains("current_token.replaced_by"));
        assertTrue(sql.contains("update refresh_tokens"));
        assertTrue(sql.contains("set session_id = id"));
        assertTrue(sql.contains("alter column session_id set not null"));
        assertTrue(sql.contains("update visitor_refresh_tokens"));
        assertTrue(sql.contains("alter table audit_log\n    add column if not exists session_id uuid"));
        assertTrue(sql.contains("alter table audit_log_archive\n    add column if not exists session_id uuid"));
        assertFalse(sql.contains("update audit_log\nset session_id"));
        assertFalse(sql.contains("token_hash"));
        assertFalse(sql.contains("raw_refresh"));
        assertFalse(sql.contains("v427__"));
    }

    @Test
    void retentionCopiesSessionIdBetweenHotAndColdAuditTables() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/audit/AuditRetentionScheduler.java"),
                StandardCharsets.UTF_8);

        assertTrue(source.contains("request_id, session_id, event_source"));
        assertTrue(source.contains("hot.request_id, hot.session_id, hot.event_source"));
    }
}
