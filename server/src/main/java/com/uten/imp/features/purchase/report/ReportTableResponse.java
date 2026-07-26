package com.uten.imp.features.purchase.report;

import java.util.List;
import java.util.Map;

/**
 * 采购报表通用响应（9 张报表共用：催料单 + 4×明细/汇总）。
 *
 * <p>设计：服务端 JOIN 出"显示就绪"行（名称已解析），前端 MasterDataTableView 按 {@link #columns}
 * 动态建列、按 {@link #facets} 渲染表头 autofilter、按 page/totalPages 翻页。
 *
 * <ul>
 *   <li>{@link #columns} 列定义（顺序=展示顺序）。</li>
 *   <li>{@link #rows} 行（LinkedHashMap，key=列键，value=显示值；日期/金额由前端按列 type 格式化）。</li>
 *   <li>{@link #facets} 每列的筛选档（value/label/count）；只对离散列（供应商/仓库/状态/是否审核…）提供。</li>
 * </ul>
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
