package com.uten.imp.features.subcontract.report;

import java.util.List;
import java.util.Map;

/**
 * 委外报表通用响应（9 张报表共用：进仓/退货/材料出/材料退 各明细+汇总 + 出入状况表）。
 *
 * <p>设计：服务端 JOIN 出"显示就绪"行（名称已解析），前端 MasterDataTableView 按 {@link #columns}
 * 动态建列、按 {@link #facets} 渲染表头 autofilter、按 page/totalPages 翻页。与 purchase 同构。
 */
public record ReportTableResponse(
        List<ReportColumn> columns,
        List<Map<String, Object>> rows,
        Map<String, List<ReportFacet>> facets,
        int page,
        int size,
        long total,
        int totalPages) {

    /** facet 空值档 sentinel（与前端 kMasterFilterNullValue 对齐）。 */
    public static final String NULL_FACET = "__null__";
}
