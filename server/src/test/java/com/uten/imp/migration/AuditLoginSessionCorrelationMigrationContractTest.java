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
    void retentionMovesWholePartitionsSoSessionIdCannotBeLost() throws Exception {
        // ADR-105: 留存不再逐列复制行, 而是整月分区 DETACH 后 ATTACH 到同形的归档表,
        // session_id 等全部列随分区原样移动。
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/audit/AuditRetentionScheduler.java"),
                StandardCharsets.UTF_8);
        assertTrue(source.contains("FROM fn_audit_retention_run()"));
        assertFalse(source.contains("INSERT INTO audit_log_archive"));
        String migration = Files.readString(Path.of(
                "src/main/resources/db/migration/V671__audit_log_monthly_partitions_append_only.sql"),
                StandardCharsets.UTF_8).toLowerCase(java.util.Locale.ROOT);
        // 归档表按在线表 LIKE 建, 列(含 session_id)与在线表完全同形, 分区才能原样 ATTACH。
        assertTrue(migration.contains("public.audit_log_archive (like public.audit_log including defaults"));
        assertTrue(migration.contains("alter table public.audit_log detach partition"));
        assertTrue(migration.contains("alter table public.audit_log_archive attach partition"));
    }
}
