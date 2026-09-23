package com.uten.imp.features.auth.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/** 敏感操作再认证: 当前登录账号的密码。 */
public record StepUpRequest(@NotBlank @Size(max = 128) String password) {}
