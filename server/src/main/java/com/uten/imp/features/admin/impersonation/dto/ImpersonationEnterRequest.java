package com.uten.imp.features.admin.impersonation.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * 进入模拟模式：admin 重新确认自己的当前密码。验通过后签发限时 modeToken，
 * 之后限时窗口内切换不同目标无需再输密码。
 */
public record ImpersonationEnterRequest(
        @NotBlank @Size(max = 128) String password) {
}
