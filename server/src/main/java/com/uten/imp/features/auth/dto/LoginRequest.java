package com.uten.imp.features.auth.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record LoginRequest(
        @NotBlank @Size(max = 128) String loginAccount,
        @NotBlank @Size(max = 128) String password
) {}
