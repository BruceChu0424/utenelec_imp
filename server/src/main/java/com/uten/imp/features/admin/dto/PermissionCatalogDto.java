package com.uten.imp.features.admin.dto;

import java.util.List;
import java.util.UUID;

/**
 * 权限目录分组（两级：module 一级 → category 二级 → 权限项）。
 * 组内权限按 sort_order + code 升序；组间由 {@code DepartmentPermissionAdminService} 按
 * 固定模块序 + 组内最小 sort_order + 子类名排序。
 *
 * <p>grantPolicy 是授权策略唯一事实源(ADR-109)，前端只按它渲染「能否批量 / 能否配给部门」，
 * 不再维护任何本地排除名单。
 */
public record PermissionCatalogDto(String module, String category, List<Item> permissions) {

    public record Item(
            UUID id,
            String code,
            String name,
            String actionType,
            String description,
            List<String> grantPolicy,
            boolean baseline,
            String sensitivity) {
    }
}
