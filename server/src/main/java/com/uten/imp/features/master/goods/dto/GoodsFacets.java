package com.uten.imp.features.master.goods.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.List;
import java.util.Map;

/**
 * 货品 facet 结果：某分类子树范围内，各筛选字段的 distinct 值桶 + 各字段空值计数。
 *
 * <p>前端据此渲染筛选栏下拉（"所有 / 空值(N) / 各具体值(N)"）。
 * colorLegacyId/unitLegacyId 桶的 value 为数字字符串。
 */
@Getter
@AllArgsConstructor
public class GoodsFacets {
    private final List<FacetBucket> code;
    private final List<FacetBucket> series;
    private final List<FacetBucket> model;
    private final List<FacetBucket> name;
    private final List<FacetBucket> spec;
    private final List<FacetBucket> material;
    private final List<FacetBucket> requireRemark;
    private final List<FacetBucket> colorLegacyId;
    private final List<FacetBucket> unitLegacyId;
    private final Map<String, Long> nullCounts;
}
