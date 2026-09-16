package com.uten.imp.common.web;

/**
 * 通用 facet 桶（值 + 命中数 + 展示标签）：服务端分页列表的表头筛选项。
 *
 * <p>与 goods 包的 FacetBucket 同形；这个放在 common.web 供 TotaledPageResponse
 * 之类的通用响应携带（2026-09-15 即时库存「所属仓库」表头筛选起用）。
 */
public record FacetBucket(String value, long count, String label) {
}
