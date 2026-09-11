package com.uten.imp.features.finance.report;

import com.uten.imp.common.report.ReportTotal;

import java.util.List;
import java.util.Map;

/**
 * 钱流报表通用响应（22 张报表共用）。与销售/采购/委外/仓库 report.ReportTableResponse 同型
 * （本类为钱流包内独立副本，避免跨模块耦合）。
 *
 * <p>服务端 JOIN 出"显示就绪"行（客户/供应商/账户/收付款类别/人员名+子类括注/总监/区域均已解析），
 * 前端 MasterDataTableView 按 {@link #columns} 动态建列、按 {@link #facets} 渲染表头 autofilter、
 * 按 page/totalPages 翻页。
 */
public record ReportTableResponse(
        List<ReportColumn> columns,
        List<Map<String, Object>> rows,
        Map<String, List<ReportFacet>> facets,
        int page,
        int size,
        long total,
        int totalPages,
        List<ReportTotal> totals) {

    /**
     * 兼容构造：不带合计的报表沿用原 7 参签名（{@code totals} 置空，前端整条合计条不渲染）。
     * 报表表格一律服务端分页，合计只能由服务端在整个结果集上算；没算就别显示，
     * 绝不让前端对当前页求和冒充总计。
     */
    public ReportTableResponse(List<ReportColumn> columns, List<Map<String, Object>> rows,
                               Map<String, List<ReportFacet>> facets, int page, int size,
                               long total, int totalPages) {
        this(columns, rows, facets, page, size, total, totalPages, List.of());
    }

    /** facet 空值档 sentinel（与前端 kMasterFilterNullValue 对齐）。 */
    public static final String NULL_FACET = "__null__";
}
