package com.uten.imp.features.master.mould.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

/**
 * facet 单个可选值（值 + 命中数）。value 统一字符串化。
 */
@Getter
@AllArgsConstructor
public class FacetBucket {
    private final String value;
    private final long count;
}
