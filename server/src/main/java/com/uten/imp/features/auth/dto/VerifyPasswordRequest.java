package com.uten.imp.features.auth.dto;

import jakarta.validation.constraints.NotBlank;

/** 改密 / 二次确认前的密码校验请求。 */
public record VerifyPasswordRequest(@NotBlank String password) {}