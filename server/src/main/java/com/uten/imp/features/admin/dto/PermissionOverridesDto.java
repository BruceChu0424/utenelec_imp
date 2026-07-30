package com.uten.imp.features.admin.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.constraints.Size;

import java.util.List;

/** 个人权限点覆盖（GET 响应 / PUT 请求共用；整体替换语义）。 */
public record PermissionOverridesDto(
        @Size(max = RequestLimits.PERMISSION_CODES) List<String> grants,
        @Size(max = RequestLimits.PERMISSION_CODES) List<String> revokes) {}
