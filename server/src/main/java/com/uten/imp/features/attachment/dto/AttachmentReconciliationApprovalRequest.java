package com.uten.imp.features.attachment.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record AttachmentReconciliationApprovalRequest(
        @NotBlank @Size(max = 255) String approvalReference) {
}
