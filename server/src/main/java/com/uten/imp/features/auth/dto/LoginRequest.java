package com.uten.imp.features.auth.dto;

import jakarta.validation.constraints.NotBlank;

public record LoginRequest(
        @NotBlank String loginAccount,
        @NotBlank String password,
        Boolean rememberDevice
) {}
