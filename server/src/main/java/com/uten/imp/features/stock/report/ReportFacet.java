package com.uten.imp.features.stock.report;

/**
 * 报表列筛选项（表头 autofilter 下拉的一档）。与 purchase/sales 同型。
 *
 * @param value 选定值（前端回传过滤用；空值档用 {@link ReportTableResponse#NULL_FACET}）
 * @param label 展示文本
 * @param count 命中行数
 */
public record ReportFacet(String value, String label, long count) {
    /** 空值档 sentinel（对应 SQL "该列 IS NULL"）。 */
    public static final String NULL_VALUE = "__null__";
}
