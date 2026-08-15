package com.uten.imp.features.org.employee.dto;

import jakarta.validation.constraints.NotNull;

import java.util.UUID;

/** 把指定员工档案附件（须为图片、归属该员工）设为头像。 */
public record SetAvatarRequest(@NotNull UUID attachmentId) {
}
