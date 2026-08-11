package com.uten.imp.features.admin.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.constraints.Size;

import java.util.List;

/** 部门直配权限点（GET 响应 / PUT 整体替换请求共用）。 */
public record DepartmentPermissionsDto(
        @Size(max = RequestLimits.PERMISSION_CODES) List<String> permissions) {}
