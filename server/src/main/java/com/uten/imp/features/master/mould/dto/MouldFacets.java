package com.uten.imp.features.master.mould.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.List;
import java.util.Map;

/**
 * 模具 facet 结果：某分类子树范围内，各筛选字段的 distinct 值桶 + 各字段空值计数。
 *
 * <p>前端据此渲染筛选栏下拉（"所有 / 空值(N) / 各具体值(N)"）。
 * 字段集合 = 表格中"有数据"的 7 列：编号/名称/存放位置/制造日期/制造商/备注/状态。
 * 表格里的模数/套数/模具类型在表无对应列，不参与 facet（下拉只显示"所有"）。
 */
@Getter
@AllArgsConstructor
public class MouldFacets {
    private final List<FacetBucket> code;
    private final List<FacetBucket> name;
    private final List<FacetBucket> place;
    private final List<FacetBucket> mstatus;
    private final List<FacetBucket> remark;
    private final List<FacetBucket> status;
    private final List<FacetBucket> manufacturer;
    private final Map<String, Long> nullCounts;
}
