package com.uten.imp.features.admin.dto;

import java.util.List;
import java.util.UUID;

/**
 * 用户有效权限分解（管理端查看用，前端直接渲染，无需平行实现合成逻辑）。
 * effective = 超管全量；否则 (baselinePermissions ∪ departmentPermissions) + grants - revokes。
 * baselinePermissions = 全员基础权限（employee 角色包，角色体系下线后仅保留此包）。
 */
public record EffectivePermissionsDto(
        UUID departmentId,
        String departmentName,
        List<String> departmentPermissions,
        List<String> baselinePermissions,
        List<String> grants,
        List<String> revokes,
        List<String> effective,
        // 超管标记：前端据此把全部权限点显示为"已授权"且不可在此调整
        // （超管恒为全量，个人覆盖对超管无意义，requireNotSuperAdmin 也已拦截写入）
        boolean superAdmin) {}
