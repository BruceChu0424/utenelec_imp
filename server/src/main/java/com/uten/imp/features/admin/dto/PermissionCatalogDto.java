package com.uten.imp.features.admin.dto;

import java.util.List;

/**
 * 权限目录分组（两级：module 一级 → category 二级 → 权限项）。
 * 组内权限按 sort_order + code 升序；组间由 {@code DepartmentPermissionAdminService} 按
 * 固定模块序 + 组内最小 sort_order + 子类名排序。
 */
public record PermissionCatalogDto(String module, String category, List<Item> permissions) {

    public record Item(String code, String name) {}
}
