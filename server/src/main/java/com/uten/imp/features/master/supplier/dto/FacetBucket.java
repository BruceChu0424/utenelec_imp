package com.uten.imp.features.master.supplier.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

/**
 * facet 单个可选值（值 + 命中数 + 展示标签）。
 *
 * <p>{@code label} 为下拉展示文案，默认等于 {@code value}；业务员（empId）桶由 Service
 * JOIN employees 解析为人名，筛选仍按 {@code value}（员工 UUID）回传后端。
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
