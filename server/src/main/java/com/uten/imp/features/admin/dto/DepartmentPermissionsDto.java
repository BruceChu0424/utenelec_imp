package com.uten.imp.features.admin.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.Map;

/** 部门直配权限点（GET 响应 / PUT 整体替换请求共用）。 */
public record DepartmentPermissionsDto(
        @Size(max = RequestLimits.PERMISSION_CODES) List<String> permissions,
        List<String> inheritedPermissions,
        Map<String, List<String>> requiredPermissions,
        Map<String, List<String>> missingDependencies,
        List<String> templatePermissions) {
    public DepartmentPermissionsDto(List<String> permissions,List<String> inheritedPermissions,
            Map<String,List<String>> requiredPermissions,Map<String,List<String>> missingDependencies) {
        this(permissions,inheritedPermissions,requiredPermissions,missingDependencies,List.of());
    }
    public DepartmentPermissionsDto(List<String> permissions) {
        this(permissions, List.of(), Map.of(), Map.of(), List.of());
    }
}
