package com.uten.imp.features.master.unit.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.List;
import java.util.Map;

/**
 * 基本单位 facet 结果：各筛选字段（编号/名称/状态/计量维度）的 distinct 值桶 + 空值计数。
 *
 * <p>前端据此渲染筛选栏下拉（"所有 / 空值(N) / 各具体值(N)"）。
 * 计量维度（dimension）存于 unit_measurement_profiles 关联表，桶值=枚举值
 * （COUNT/MASS/…）、空值=未设置维度的单位数。
 */
@Getter
@AllArgsConstructor
public class UnitFacets {
    private final List<FacetBucket> code;
    private final List<FacetBucket> name;
    private final List<FacetBucket> status;
    private final List<FacetBucket> dimension;
    private final Map<String, Long> nullCounts;
}
