package com.uten.imp.features.admin.impersonation.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

import java.util.UUID;

/** 切换到目标员工身份：携带 enter 签发的 modeToken + 目标员工档案 id。 */
public record ImpersonationStartRequest(
        @NotNull UUID targetEmployeeId,
        @NotBlank String modeToken) {
}
