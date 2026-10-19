package com.uten.imp.features.master.mould.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.List;
import java.util.Map;

/**
 * 模具 facet 结果：某分类子树范围内，各筛选字段的 distinct 值桶 + 各字段空值计数。
 *
 * <p>前端据此渲染筛选栏下拉（"所有 / 空值(N) / 各具体值(N)"）。
 * 字段集合 = 表格中"有数据"的列：编号/名称/模数/存放位置/制造日期/制造商/备注/状态。
 * 套数为数值列（同货品库存量口径）不进 facet；模具类型无数据源不参与。
 */
@Getter
@AllArgsConstructor
public class MouldFacets {
    private final List<FacetBucket> code;
    private final List<FacetBucket> name;
    private final List<FacetBucket> qty;
    private final List<FacetBucket> place;
    private final List<FacetBucket> mstatus;
    private final List<FacetBucket> remark;
    private final List<FacetBucket> status;
    private final List<FacetBucket> manufacturer;
    private final Map<String, Long> nullCounts;
}
