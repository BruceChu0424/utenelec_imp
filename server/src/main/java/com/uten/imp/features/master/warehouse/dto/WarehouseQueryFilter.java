package com.uten.imp.features.master.warehouse.dto;

import java.util.Set;
import java.util.UUID;

/**
 * 仓库列表查询条件值对象（keyword + 字段精确筛选 + 空值字段集合）。
 *
 * <p>parentId=上级仓库（UUID）等值（nullFields 含 parentId=筛顶层/独立仓）；
 * accountable=是否参与核算（true/false）等值。
 */
public record WarehouseQueryFilter(
        String keyword,
        Set<String> nullFields,
        String code,
        String name,
        String status,
        String location,
        UUID parentId,
        Boolean accountable) {
}
