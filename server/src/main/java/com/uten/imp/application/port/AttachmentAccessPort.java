package com.uten.imp.application.port;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

/**
 * Public attachment boundary for business features that display or select attachments.
 *
 * <p>The attachment feature owns persistence, lifecycle validation, and owner-policy dispatch.
 * Consumers receive only immutable projections and never depend on attachment entities or
 * repositories.</p>
 */
public interface AttachmentAccessPort {

    List<AttachmentView> listVisible(String ownerType, UUID ownerId);

    /**
     * Selects one clean image as the owner's avatar and returns its opaque storage key.
     */
    String selectAvatar(String ownerType, UUID ownerId, UUID attachmentId);

    record AttachmentView(
            UUID id,
            String ownerType,
            UUID ownerId,
            String storageKey,
            String originalName,
            String contentType,
            long sizeBytes,
            Instant uploadedAt,
            UUID uploadedBy,
            String downloadUrl,
            String category,
            boolean avatar) {
    }
}
