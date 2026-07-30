package com.uten.imp.features.auth.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/** 改密 / 二次确认前的密码校验请求。 */
public record VerifyPasswordRequest(@NotBlank @Size(max = 128) String password) {}
