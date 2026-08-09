package com.uten.imp.features.attachment.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;
import jakarta.validation.constraints.Size;

import java.util.UUID;

/**
 * 客户端直传完成后绑定：服务端校验对象已到位（HEAD/读文件），落 attachments 行。
 */
public record AttachmentConfirmRequest(
        @NotBlank @Size(max = 255) String storageKey,
        @NotBlank @Size(max = 64) String ownerType,
        UUID ownerId,
        @NotBlank @Size(max = 255) String originalName,
        @NotBlank @Size(max = 255) String contentType,
        @NotNull @Positive Long sizeBytes,
        @Size(max = 64) String sha256) {
}
