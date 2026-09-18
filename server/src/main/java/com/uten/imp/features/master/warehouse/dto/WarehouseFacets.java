package com.uten.imp.features.master.warehouse.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.List;
import java.util.Map;

/**
 * 仓库 facet 结果：编号/名称/状态/上级仓库/核算 的 distinct 值桶 + 空值计数。
 *
 * <p>上级仓库（parent）桶值=parent_id（UUID）、label=上级仓名；空值=顶层/独立仓。
 * 核算（accountable）桶值=true/false、label=是/否（列 NOT NULL，无空值桶）。
 */
@Getter
@AllArgsConstructor
public class WarehouseFacets {
    private final List<FacetBucket> code;
    private final List<FacetBucket> name;
    private final List<FacetBucket> status;
    private final List<FacetBucket> parent;
    private final List<FacetBucket> accountable;
    private final Map<String, Long> nullCounts;
}
