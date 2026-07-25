package com.uten.imp.features.master.currency.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.List;
import java.util.Map;

/**
 * 币种 facet 结果：各筛选字段（编号/名称/状态）的 distinct 值桶 + 各字段空值计数。
 *
 * <p>exchange_rate 为数字字段，不进 facet（仅列表/详情展示）。
 */
@Getter
@AllArgsConstructor
public class CurrencyFacets {
    private final List<FacetBucket> code;
    private final List<FacetBucket> name;
    private final List<FacetBucket> status;
    private final Map<String, Long> nullCounts;
}
