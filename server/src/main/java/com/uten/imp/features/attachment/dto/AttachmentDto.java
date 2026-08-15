package com.uten.imp.features.attachment.dto;

import java.time.Instant;
import java.util.UUID;

public record AttachmentDto(
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
