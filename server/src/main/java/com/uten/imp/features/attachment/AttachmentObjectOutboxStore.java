package com.uten.imp.features.attachment;

import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

import java.sql.Timestamp;
import java.time.Instant;
import java.util.UUID;

@Service
@RequiredArgsConstructor
class AttachmentObjectOutboxStore {
    private final JdbcTemplate jdbc;

    void enqueueStaging(UUID uploadSessionId, String storageKey, String versionId, String storageProvider) {
        enqueue(null, uploadSessionId, "DELETE_STAGING", storageKey, versionId,
                Instant.now(), storageProvider);
    }

    void enqueueStagingAfter(UUID uploadSessionId, String storageKey, String versionId,
                             Instant deleteNotBefore, String storageProvider) {
        enqueue(null, uploadSessionId, "DELETE_STAGING", storageKey, versionId,
                deleteNotBefore, storageProvider);
    }

    void enqueueFinal(UUID attachmentId, String storageKey, String versionId, String storageProvider) {
        enqueue(attachmentId, null, "DELETE_FINAL", storageKey, versionId,
                Instant.now(), storageProvider);
    }

    private void enqueue(UUID attachmentId, UUID uploadSessionId, String operation,
                         String storageKey, String versionId, Instant availableAt, String storageProvider) {
        String dedupeKey = storageProvider + "|" + operation + "|" + storageKey + "|"
                + (versionId == null ? "<local>" : versionId);
        jdbc.update("""
                INSERT INTO attachment_object_outbox (
                    attachment_id, upload_session_id, operation, storage_key,
                    storage_version, dedupe_key, available_at, storage_provider)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (dedupe_key) DO NOTHING
                """, attachmentId, uploadSessionId, operation, storageKey, versionId,
                dedupeKey, Timestamp.from(availableAt), storageProvider);
    }

    /** An expired upload needs a fresh physical check after its last possible staging write. */
    void enqueueExpiryVerification(UUID sessionId,String key,Instant verifyAt,String provider) {
        // A separate identity survives an earlier successful/absent staging lookup.
        // Repeated expiry lookup retries reuse this intent rather than multiply deletes.
        String dedupe=provider+"|EXPIRY_VERIFY|DELETE_STAGING|"+sessionId;
        jdbc.update("""
                INSERT INTO attachment_object_outbox(upload_session_id,operation,storage_key,
                    dedupe_key,available_at,storage_provider)
                VALUES (?,'DELETE_STAGING',?,?,?,?) ON CONFLICT(dedupe_key) DO NOTHING
                """,sessionId,key,dedupe,Timestamp.from(verifyAt),provider);
    }
}
