package com.uten.imp.features.master.referencemethod;

/**
 * facet 单个可选值（值 + 命中数）。value 统一字符串化。
 */
public record FacetBucket(String value, long count) {
}
