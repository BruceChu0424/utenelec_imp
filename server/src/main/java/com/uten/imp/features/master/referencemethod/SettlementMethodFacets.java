package com.uten.imp.features.master.referencemethod;

import java.util.List;
import java.util.Map;

/**
 * 结算方式 facet 结果：各筛选字段（状态/系统角色/到期基准/到期规则）的 distinct 值桶
 * + 各字段空值计数。
 *
 * <p>编号/名称是自由文本列，不进 facet；前端据此渲染表头筛选下拉
 * （"所有 / 空值(N) / 各具体值(N)"），范式同 {@code ColorFacets}。
 */
public record SettlementMethodFacets(
        List<FacetBucket> status,
        List<FacetBucket> systemRole,
        List<FacetBucket> termsBase,
        List<FacetBucket> dueRule,
        Map<String, Long> nullCounts) {
}
