package com.uten.imp.features.production.report;

import com.uten.imp.common.report.ReportTotal;

import java.util.List;
import java.util.Map;

/**
 * 生产报表通用响应（生产计划明细/汇总共用）。
 *
 * <p>设计：服务端 JOIN 出"显示就绪"行（货品/颜色/类别/人员名称已解析），前端
 * MasterDataTableView 按 {@link #columns} 动态建列、按 {@link #facets} 渲染表头
 * autofilter、按 page/totalPages 翻页。范式同采购/销售报表（ReportTableResponse）。
 *
 * <ul>
 *   <li>{@link #columns} 列定义（顺序=展示顺序）。</li>
 *   <li>{@link #rows} 行（LinkedHashMap，key=列键，value=显示值；日期/金额由前端按列 type 格式化）。</li>
 *   <li>{@link #facets} 每列的筛选档（value/label/count）；只对离散列（是否审核/是否完成/车间/类别…）提供。</li>
 * </ul>
 */
public record ReportTableResponse(
        List<ReportColumn> columns,
        List<Map<String, Object>> rows,
        Map<String, List<ReportFacet>> facets,
        int page,
        int size,
        long total,
        int totalPages,
        Map<String, Object> meta,
        List<ReportTotal> totals) {

    public ReportTableResponse(List<ReportColumn> columns, List<Map<String, Object>> rows,
                               Map<String, List<ReportFacet>> facets, int page, int size,
                               long total, int totalPages) {
        this(columns, rows, facets, page, size, total, totalPages, Map.of(), List.of());
    }

    /**
     * 兼容构造：带 meta、不带合计（{@code totals} 置空，前端整条合计条不渲染）。
     * 报表表格一律服务端分页，合计只能由服务端在整个结果集上算；没算就别显示，
     * 绝不让前端对当前页求和冒充总计。
     */
    public ReportTableResponse(List<ReportColumn> columns, List<Map<String, Object>> rows,
                               Map<String, List<ReportFacet>> facets, int page, int size,
                               long total, int totalPages, Map<String, Object> meta) {
        this(columns, rows, facets, page, size, total, totalPages, meta, List.of());
    }

    /** facet 空值档 sentinel（与前端 kMasterFilterNullValue 对齐）。 */
    public static final String NULL_FACET = "__null__";
}
