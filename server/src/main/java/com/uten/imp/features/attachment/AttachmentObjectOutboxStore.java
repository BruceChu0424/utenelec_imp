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

    void enqueueStaging(UUID uploadSessionId, String storageKey, String versionId) {
        enqueue(null, uploadSessionId, "DELETE_STAGING", storageKey, versionId,
                Instant.now());
    }

    void enqueueStagingAfter(UUID uploadSessionId, String storageKey, String versionId,
                             Instant deleteNotBefore) {
        enqueue(null, uploadSessionId, "DELETE_STAGING", storageKey, versionId,
                deleteNotBefore);
    }

    void enqueueFinal(UUID attachmentId, String storageKey, String versionId) {
        enqueue(attachmentId, null, "DELETE_FINAL", storageKey, versionId,
                Instant.now());
    }

    private void enqueue(UUID attachmentId, UUID uploadSessionId, String operation,
                         String storageKey, String versionId, Instant availableAt) {
        String dedupeKey = operation + "|" + storageKey + "|"
                + (versionId == null ? "<local>" : versionId);
        jdbc.update("""
                INSERT INTO attachment_object_outbox (
                    attachment_id, upload_session_id, operation, storage_key,
                    storage_version, dedupe_key, available_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (dedupe_key) DO NOTHING
                """, attachmentId, uploadSessionId, operation, storageKey, versionId,
                dedupeKey, Timestamp.from(availableAt));
    }
}
