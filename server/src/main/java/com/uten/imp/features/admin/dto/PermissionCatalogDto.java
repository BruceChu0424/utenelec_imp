package com.uten.imp.features.admin.dto;

import java.util.List;

/** 权限目录分组（按 category 分组，组内 sort_order + code 升序）。 */
public record PermissionCatalogDto(String category, List<Item> permissions) {

    public record Item(String code, String name) {}
}
