package com.uten.imp.common.web;

import com.uten.imp.common.report.ReportTotal;

import java.util.List;
import java.util.Map;

/**
 * 带「表格下方合计」的分页响应（{@link PageResponse} + {@code totals}）。
 *
 * <p><b>为什么不是直接往 PageResponse 上加字段</b>：PageResponse 被 170+ 个端点用着，
 * 加一个 final 字段会推翻所有 {@code new PageResponse<>(...)}。本类只是它的子类，
 * JSON 形状完全不变（{@code items/page/size/total/totalPages}）、只多一个 {@code totals}，
 * 前端 {@code PagedResult.fromJson} 读不到时退化成空列表，老客户端零感知。
 *
 * <p><b>合计必须由服务端算</b>：列表一律服务端分页，前端对「当前页」求和会得出一个
 * 看着像总计、其实只覆盖一页的数——比不显示更糟。{@code totals} 由
 * {@link com.uten.imp.common.report.ReportTotalsCalculator} 用与列表<b>完全相同</b>的
 * 过滤条件（含对象级授权谓词）在整个结果集上聚合，与翻到第几页无关；数量按单位分组、
 * 金额按币种分组，绝不跨单位/跨币种相加。
 */
public class TotaledPageResponse<T> extends PageResponse<T> {

    private final List<ReportTotal> totals;

    /** 表头筛选桶（可选；null=本端点无 facet，JSON 不输出，老客户端零感知）。 */
    private final Map<String, List<FacetBucket>> facets;

    /** 各 facet 字段的空值行数（可选；供 "(空)(N)" 桶，与 facets 成对出现）。 */
    private final Map<String, Long> facetNullCounts;

    public TotaledPageResponse(PageResponse<T> page, List<ReportTotal> totals) {
        this(page, totals, null, null);
    }

    public TotaledPageResponse(PageResponse<T> page, List<ReportTotal> totals,
                               Map<String, List<FacetBucket>> facets) {
        this(page, totals, facets, null);
    }

    public TotaledPageResponse(PageResponse<T> page, List<ReportTotal> totals,
                               Map<String, List<FacetBucket>> facets,
                               Map<String, Long> facetNullCounts) {
        super(page.getItems(), page.getPage(), page.getSize(), page.getTotal(), page.getTotalPages());
        this.totals = totals == null ? List.of() : List.copyOf(totals);
        this.facets = facets;
        this.facetNullCounts = facetNullCounts;
    }

    public List<ReportTotal> getTotals() {
        return totals;
    }

    @com.fasterxml.jackson.annotation.JsonInclude(
            com.fasterxml.jackson.annotation.JsonInclude.Include.NON_NULL)
    public Map<String, List<FacetBucket>> getFacets() {
        return facets;
    }

    @com.fasterxml.jackson.annotation.JsonInclude(
            com.fasterxml.jackson.annotation.JsonInclude.Include.NON_NULL)
    public Map<String, Long> getFacetNullCounts() {
        return facetNullCounts;
    }
}
