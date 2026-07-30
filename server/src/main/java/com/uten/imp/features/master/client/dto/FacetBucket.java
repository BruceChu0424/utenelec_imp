package com.uten.imp.features.master.client.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

/**
 * facet 单个可选值（值 + 命中数）。value 统一字符串化（数值字段也转字符串）。
 *
 * <p>与 {@code com.uten.imp.features.master.goods.dto.FacetBucket} 结构同构，独立成类
 * 便于各模块 DTO 自治（不跨 package 引用）。
 */
@Getter
@AllArgsConstructor
public class FacetBucket {
    private final String value;
    private final long count;
}
