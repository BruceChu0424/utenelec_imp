package com.uten.imp.features.master.goods.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

/**
 * facet 单个可选值（值 + 命中数 + 展示标签）。value 统一字符串化（颜色/单位 legacy id 为数字也转字符串）。
 *
 * <p>{@code label} 为下拉展示文案，默认等于 {@code value}；颜色/单位桶由 Service 解析为名称
 * （如 345 → "白色"），筛选仍按 {@code value}（legacy id）回传后端。前端 {@code MasterFacetBucket}
 * 读 label、显 label、回 value。
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
