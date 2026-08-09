package com.uten.imp.features.attachment.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;
import jakarta.validation.constraints.Size;

import java.util.UUID;

/**
 * 申请一次上传：服务端生成 storageKey + 客户端直传目标 URL。
 * 客户端拿到响应后把字节 PUT 到 {@code url}，再调 confirm 绑定到业务单据。
 */
public record AttachmentPresignRequest(
        @NotBlank @Size(max = 64) String ownerType,
        UUID ownerId,
        @NotBlank @Size(max = 255) String fileName,
        @NotBlank @Size(max = 255) String contentType,
        @NotNull @Positive Long sizeBytes) {
}
