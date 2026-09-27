package com.uten.imp.features.auth.dto;

import jakarta.validation.constraints.NotBlank;

/** 敏感操作再认证: 当前登录账号的密码。 */
public record StepUpRequest(@NotBlank String password) {}
