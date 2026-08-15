package com.uten.imp.features.attachment.dto;

import java.time.Instant;
import java.util.UUID;

public record AttachmentReconciliationFindingDto(
        UUID id,
        String objectLocation,
        String storageKey,
        String storageVersion,
        long sizeBytes,
        String findingState,
        int observationCount,
        Instant firstSeenAt,
        Instant lastSeenAt,
        String evidenceSha256) {
}
