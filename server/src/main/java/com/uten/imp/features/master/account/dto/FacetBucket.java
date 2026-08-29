package com.uten.imp.features.master.account.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

/** facet 单个可选值（机器值 + 命中数 + 中文显示标签）。 */
@Getter
@AllArgsConstructor
public class FacetBucket {
    private final String value;
    private final long count;
    private final String label;

    public FacetBucket(String value, long count) {
        this(value, count, value);
    }
}
