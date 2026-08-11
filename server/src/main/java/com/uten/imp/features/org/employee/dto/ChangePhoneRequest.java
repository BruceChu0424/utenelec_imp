package com.uten.imp.features.org.employee.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/** 更换手机号（ADR-021 §三）：新号同步为登录账号并吊销旧会话。 */
public record ChangePhoneRequest(
        @NotBlank(message = "新手机号不能为空")
        @Size(max = 20)
        String newPhone) {}
