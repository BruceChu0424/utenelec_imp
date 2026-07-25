package com.uten.imp.features.master.warehouse.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.List;
import java.util.Map;

/**
 * 仓库 facet 结果：编号/名称/状态的 distinct 值桶 + 空值计数。
 */
@Getter
@AllArgsConstructor
public class WarehouseFacets {
    private final List<FacetBucket> code;
    private final List<FacetBucket> name;
    private final List<FacetBucket> status;
    private final Map<String, Long> nullCounts;
}
