package com.uten.imp.features.admin.dto;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 用户有效权限分解（管理端查看用，前端直接渲染，无需平行实现合成逻辑）。
 * effective = 超管为全量目录码 − 个人收回（2026-10-30 起个人收回压过超管默认）；
 * 否则 (baselinePermissions ∪ departmentPermissions) + grants + managerGrants - revokes。
 * baselinePermissions = 全员基础权限（employee 角色包，角色体系下线后仅保留此包）。
 */
public record EffectivePermissionsDto(
        UUID departmentId,
        String departmentName,
        List<String> departmentPermissions,
        List<String> baselinePermissions,
        List<String> grants,
        List<String> confirmedGrants,
        List<String> legacyUnknownGrants,
        List<String> legacyUnknownRevokes,
        List<String> managerGrants,
        List<String> revokes,
        List<String> effective,
        // 超管标记：默认全部目录码（来源显示「超管默认」），个人收回可压过默认并可在
        // 权限页调整；SUPERADMIN_ONLY 码只随身份生效，前端仍显示为锁定
        boolean superAdmin,
        Map<String, List<String>> requiredPermissions,
        Map<String, List<String>> missingDependencies,
        List<String> templatePermissions) {}
