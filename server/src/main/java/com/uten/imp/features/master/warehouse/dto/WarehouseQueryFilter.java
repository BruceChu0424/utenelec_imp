package com.uten.imp.features.master.warehouse.dto;

import java.util.Set;

/**
 * 仓库列表查询条件值对象（keyword + 字段精确筛选 + 空值字段集合）。
 */
public record WarehouseQueryFilter(
        String keyword,
        Set<String> nullFields,
        String code,
        String name,
        String status,
        String location) {
}
