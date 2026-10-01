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
        boolean avatar,
        boolean deleted,Instant deletedAt,UUID deletedBy,String deletedByName,String deletedReason,
        boolean historyReadOnly,String originalAvailability,String historyDownloadUrl) {
    public AttachmentDto(UUID id,String ownerType,UUID ownerId,String storageKey,String originalName,String contentType,
            long sizeBytes,Instant uploadedAt,UUID uploadedBy,String downloadUrl,String category,boolean avatar) {
        this(id,ownerType,ownerId,storageKey,originalName,contentType,sizeBytes,uploadedAt,uploadedBy,downloadUrl,category,avatar,
                false,null,null,null,null,false,"UNKNOWN",null);
    }
}
