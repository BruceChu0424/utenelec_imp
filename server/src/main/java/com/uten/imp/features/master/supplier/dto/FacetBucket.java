package com.uten.imp.features.master.supplier.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

/**
 * facet 单个可选值（值 + 命中数）。value 统一字符串化（empId 等业务员 legacy id
 * 即便是数字也转字符串），与货品 facet 一致。
 */
@Getter
@AllArgsConstructor
public class FacetBucket {
    private final String value;
    private final long count;
}
