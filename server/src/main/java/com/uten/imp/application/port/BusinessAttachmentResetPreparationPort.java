package com.uten.imp.application.port;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

/** Test-reset preparation only: reviewed deletion intents, never direct file deletion. */
public interface BusinessAttachmentResetPreparationPort {
    record Item(String type, UUID id, String ownerType, UUID ownerId, String fileName,
                String state, Instant waitUntil, String message) {}
    record Preview(String database, String fingerprint, long blockingCount,
                   List<Item> items, boolean hasMore) {}
    record Confirmation(String database, String fingerprint) {}
    Preview preview(UUID operatorId);
    Preview prepare(UUID operatorId, String operatorAccount, Confirmation confirmation);
}
