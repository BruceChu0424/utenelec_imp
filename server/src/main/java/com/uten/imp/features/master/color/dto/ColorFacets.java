package com.uten.imp.features.master.color.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.List;
import java.util.Map;

/**
 * 颜色 facet 结果：各筛选字段（编号/名称/状态）的 distinct 值桶 + 各字段空值计数。
 *
 * <p>前端据此渲染筛选栏下拉（"所有 / 空值(N) / 各具体值(N)"）。
 */
@Getter
@AllArgsConstructor
public class ColorFacets {
    private final List<FacetBucket> code;
    private final List<FacetBucket> name;
    private final List<FacetBucket> status;
    private final Map<String, Long> nullCounts;
}
