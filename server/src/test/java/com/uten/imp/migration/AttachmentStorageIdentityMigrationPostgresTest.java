package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Nonempty V532 history, exact provider routing, and database-enforced identity. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class AttachmentStorageIdentityMigrationPostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate db;
    private static final UUID OWNER = UUID.randomUUID();
    private static String originalFacts;

    @BeforeAll
    static void migrateHistory() {
        POSTGRES.start();
        var source = new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        db = new JdbcTemplate(source);
        Flyway.configure().dataSource(source).locations("classpath:db/migration").target("532").load().migrate();
        for (String key : new String[]{"known-oss.pdf", "unknown-unversioned.pdf"}) {
            db.update("""
                    INSERT INTO attachments(id,owner_type,owner_id,storage_key,storage_version,
                        original_name,content_type,size_bytes,sha256,lifecycle_state,
                        scan_engine,scanned_at,promoted_at)
                    VALUES (?, 'EMPLOYEE', ?, ?, ?, ?, 'application/pdf', 1031,
                        repeat('a',64),'CLEAN','historical-scanner',now(),now())
                    """, UUID.randomUUID(), OWNER, key, key.startsWith("known") ? "oss-original-version" : null, key);
        }
        db.update("""
                INSERT INTO attachment_upload_sessions(id,storage_key,owner_type,owner_id,user_id,
                    original_name,content_type,expected_size_bytes,expires_at,status,final_version,sha256)
                VALUES (?, 'known-oss.pdf', 'EMPLOYEE', ?, ?, 'known-oss.pdf','application/pdf',1031,
                    now()-interval '1 day','PROMOTED','oss-original-version',repeat('a',64))
                """, UUID.randomUUID(), OWNER, UUID.randomUUID());
        db.update("""
                INSERT INTO attachment_object_outbox(operation,storage_key,storage_version,dedupe_key)
                VALUES ('DELETE_FINAL','known-orphan.pdf','oss-version','DELETE_FINAL|known-orphan.pdf|oss-version'),
                       ('DELETE_FINAL','ambiguous.pdf',NULL,'DELETE_FINAL|ambiguous.pdf|<local>')
                """);
        db.update("""
                INSERT INTO attachment_reconciliation_findings(object_location,storage_key,
                    storage_version,size_bytes,evidence_sha256)
                VALUES ('FINAL','same-key.pdf','oss-version',1031,repeat('b',64)),
                       ('STAGING','unknown.pdf',NULL,1031,repeat('c',64))
                """);
        originalFacts = facts();
        Flyway.configure().dataSource(source).locations("classpath:db/migration").target("533").load().migrate();
    }

    @AfterAll static void stop() { POSTGRES.stop(); }

    @Test void originalBytesAndBusinessBindingsAreUnchanged() {
        assertThat(facts()).isEqualTo(originalFacts);
        assertThat(db.queryForObject("SELECT count(*) FROM flyway_schema_history WHERE success", Integer.class)).isEqualTo(492);
        assertThat(db.queryForObject("SELECT storage_provider FROM attachments WHERE storage_key='known-oss.pdf'", String.class)).isEqualTo("oss");
        assertThat(db.queryForObject("SELECT stored_size_bytes FROM attachments WHERE storage_key='known-oss.pdf'", Long.class)).isEqualTo(1031L);
        assertThat(db.queryForObject("SELECT storage_provider FROM attachments WHERE storage_key='unknown-unversioned.pdf'", String.class)).isEqualTo("legacy_unknown");
        assertThat(db.queryForObject("SELECT stored_size_bytes FROM attachments WHERE storage_key='unknown-unversioned.pdf'", Long.class)).isNull();
        assertThat(db.queryForObject("SELECT storage_provider FROM attachment_upload_sessions", String.class)).isEqualTo("oss");
        assertThat(db.queryForList("SELECT dedupe_key FROM attachment_object_outbox ORDER BY storage_key", String.class))
                .containsExactly("legacy_unknown|DELETE_FINAL|ambiguous.pdf|<local>", "oss|DELETE_FINAL|known-orphan.pdf|oss-version");
    }

    @Test void compressedPhysicalSizeDoesNotChangeOriginalIdentity() {
        String key = "compressed-internal.txt";
        insertInternal(key, 200L, "GZIP");
        assertThat(db.queryForMap("SELECT size_bytes,stored_size_bytes,storage_encoding FROM attachments WHERE storage_key=?", key))
                .containsEntry("size_bytes", 1031L).containsEntry("stored_size_bytes", 200L).containsEntry("storage_encoding", "GZIP");
        // Identity format also has a private storage header, not just original payload.
        insertInternal("identity-internal.txt", 1088L, "IDENTITY");
    }

    @Test void incompleteRepresentationAndMissingProviderAreRejected() {
        assertThatThrownBy(() -> insertInternal("no-size.txt", null, "GZIP")).hasMessageContaining("check constraint");
        assertThatThrownBy(() -> insertInternal("no-codec.txt", 200L, null)).hasMessageContaining("check constraint");
        assertThatThrownBy(() -> insertInternal("bad-codec.txt", 200L, "JPEG")).hasMessageContaining("check constraint");
        assertThatThrownBy(() -> db.update("""
                INSERT INTO attachments(id,owner_type,owner_id,storage_key,original_name,size_bytes)
                VALUES (?, 'EMPLOYEE', ?, 'no-provider.txt', 'original.txt',1031)
                """, UUID.randomUUID(), OWNER)).hasMessageContaining("storage_provider");
    }

    @Test void confirmedIdentityCannotBeReboundOrReopenedForModification() {
        for (String change : new String[]{"size_bytes=1", "sha256=repeat('f',64)",
                "storage_provider='local'", "lifecycle_state='LEGACY_UNVERIFIED'", "owner_id=gen_random_uuid()"}) {
            assertThatThrownBy(() -> db.update("UPDATE attachments SET " + change + " WHERE storage_key='known-oss.pdf'"))
                    .hasMessageContaining("Confirmed attachment");
        }
        assertThatThrownBy(() -> db.update("UPDATE attachment_upload_sessions SET status='REJECTED' WHERE storage_key='known-oss.pdf'"))
                .hasMessageContaining("Promoted attachment session");
    }

    @Test void metadataDeletionLifecycleDoesNotRewriteContent() {
        insertInternal("delete-internal.txt", 200L, "GZIP");
        db.update("UPDATE attachments SET lifecycle_state='DELETE_PENDING',delete_requested_at=now() WHERE storage_key='delete-internal.txt'");
        db.update("UPDATE attachments SET lifecycle_state='DELETE_FAILED',delete_failure='IO_FAILURE' WHERE storage_key='delete-internal.txt'");
        db.update("UPDATE attachments SET lifecycle_state='DELETED',delete_failure=NULL WHERE storage_key='delete-internal.txt'");
        assertThat(db.queryForObject("SELECT sha256 FROM attachments WHERE storage_key='delete-internal.txt'", String.class)).isEqualTo("a".repeat(64));
    }

    @Test void orphanEvidenceIsProviderScopedWithoutRewritingOldProof() {
        db.update("""
                INSERT INTO attachment_reconciliation_findings(storage_provider,object_location,
                    storage_key,storage_version,size_bytes,evidence_sha256)
                VALUES ('internal','FINAL','same-key.pdf','oss-version',1031,repeat('d',64))
                """);
        assertThat(db.queryForObject("SELECT count(*) FROM attachment_reconciliation_findings WHERE storage_key='same-key.pdf'", Integer.class)).isEqualTo(2);
        assertThat(db.queryForObject("SELECT evidence_sha256 FROM attachment_reconciliation_findings WHERE storage_provider='oss'", String.class)).isEqualTo("b".repeat(64));
        assertThat(db.queryForObject("SELECT storage_provider FROM attachment_reconciliation_findings WHERE storage_key='unknown.pdf'", String.class)).isEqualTo("legacy_unknown");
    }

    private static void insertInternal(String key, Long storedBytes, String encoding) {
        db.update("""
                INSERT INTO attachments(id,owner_type,owner_id,storage_key,storage_version,original_name,
                    content_type,size_bytes,sha256,lifecycle_state,scan_engine,scanned_at,promoted_at,
                    storage_provider,stored_size_bytes,storage_encoding)
                VALUES (?, 'EMPLOYEE', ?, ?, 'internal-v1:example', ?, 'text/plain',1031,
                    repeat('a',64),'CLEAN','scanner',now(),now(),'internal',?,?)
                """, UUID.randomUUID(), OWNER, key, key, storedBytes, encoding);
    }

    private static String facts() {
        return db.queryForObject("""
                SELECT string_agg(owner_type||'|'||owner_id||'|'||storage_key||'|'||original_name||'|'||
                    content_type||'|'||size_bytes||'|'||sha256||'|'||lifecycle_state, E'\n' ORDER BY storage_key)
                FROM attachments WHERE storage_key IN ('known-oss.pdf','unknown-unversioned.pdf')
                """, String.class);
    }
}
