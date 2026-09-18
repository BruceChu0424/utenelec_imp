package com.uten.imp.features.master.warehouse.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

/**
 * facet 单个可选值（值 + 命中数 + 展示标签）。
 *
 * <p>{@code label} 为下拉展示文案，默认等于 {@code value}；上级仓库（parent）桶由
 * Service 自 JOIN 解析仓名、核算（accountable）桶映射是/否，筛选仍按 {@code value} 回传。
 */
@Getter
@AllArgsConstructor
public class FacetBucket {
    private final String value;
    private final long count;
    private final String label;

    /** 兼容：无 label 时 label=value。 */
    public FacetBucket(String value, long count) {
        this(value, count, value);
    }
}
