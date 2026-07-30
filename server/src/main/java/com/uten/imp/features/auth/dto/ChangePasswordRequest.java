package com.uten.imp.features.auth.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record ChangePasswordRequest(
        @NotBlank @Size(max = 128) String oldPassword,
        @NotBlank @Size(max = 128) String newPassword
) {}
