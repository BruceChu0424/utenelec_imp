package com.uten.imp.features.auth.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record LoginRequest(
        @NotBlank @Size(max = 128) String loginAccount,
        @NotBlank String password,
        @Size(max = 16) String otpCode
) {
    public LoginRequest(String loginAccount, String password) { this(loginAccount, password, null); }
    @Override public String toString() { return "LoginRequest[credentials=REDACTED]"; }
}
