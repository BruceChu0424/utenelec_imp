package com.uten.imp.features.admin.dto;

import java.util.List;

/** 部门直配权限点（GET 响应 / PUT 整体替换请求共用）。 */
public record DepartmentPermissionsDto(List<String> permissions) {}
