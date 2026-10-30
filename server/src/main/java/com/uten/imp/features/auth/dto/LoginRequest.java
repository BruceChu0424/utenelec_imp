package com.uten.imp.features.auth.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record LoginRequest(
        @NotBlank @Size(max = 128) String loginAccount,
        @NotBlank String password,
        // 客户端自报的设备名（如「Windows 客户端」「网页端 · Chrome」），仅用于
        // 单设备顶号时向被顶设备说明「账号在哪台设备登录」，不是安全边界。
        @Size(max = 64) String deviceName
) {
    public LoginRequest(String loginAccount, String password) { this(loginAccount, password, null); }
    @Override public String toString() { return "LoginRequest[credentials=REDACTED]"; }
}
