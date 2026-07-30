package com.uten.imp.common.export;

/**
 * 导出列定义。与各报表的 {@code ReportColumn} 解耦——报表导出时把 key/label/type 映射过来，
 * 主档/单据列表导出由各自的列 spec 构造。type 决定单元格格式（见 {@link XlsxExportService}）。
 *
 * @param key  行 Map 取值键（与查询投影别名 / 行模型字段对齐）
 * @param label 表头文案
 * @param type text / date / money / number / bool（常量见下）
 */
public record ExportColumn(String key, String label, String type) {
    public static final String TEXT = "text";
    public static final String DATE = "date";
    public static final String MONEY = "money";
    public static final String NUMBER = "number";
    public static final String BOOL = "bool";
}
