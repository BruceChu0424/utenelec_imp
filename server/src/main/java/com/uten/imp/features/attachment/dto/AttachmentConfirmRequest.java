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
        @NotBlank @Size(max = 4096) String confirmToken,
        @NotBlank @Size(max = 64) String ownerType,
        @NotNull UUID ownerId,
        @NotBlank @Size(max = 255) String originalName,
        @NotBlank @Size(max = 255) String contentType,
        @NotNull @Positive Long sizeBytes,
        @Size(max = 64) String sha256,
        /** 文档分类（员工档案：合同/身份证件/学历证书/照片/其他）；可为空。 */
        @Size(max = 48) String category) {
}
