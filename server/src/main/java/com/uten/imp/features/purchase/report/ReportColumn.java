package com.uten.imp.features.purchase.report;

/**
 * 报表列定义（驱动前端 MasterDataTableView 动态建列）。
 *
 * @param key   列键（= SQL SELECT 别名 = 行 Map 的 key = facet 的 key）
 * @param label 列标题（中文）
 * @param type  text / date / number / money / bool / int —— 前端按类型格式化与对齐
 * @param width 建议列宽（px），可空
 */
public record ReportColumn(String key, String label, String type, Integer width) {
    public static ReportColumn text(String key, String label) { return new ReportColumn(key, label, "text", null); }
    public static ReportColumn text(String key, String label, int w) { return new ReportColumn(key, label, "text", w); }
    public static ReportColumn date(String key, String label) { return new ReportColumn(key, label, "date", 120); }
    public static ReportColumn date(String key, String label, int w) { return new ReportColumn(key, label, "date", w); }
    public static ReportColumn number(String key, String label) { return new ReportColumn(key, label, "number", 110); }
    public static ReportColumn money(String key, String label) { return new ReportColumn(key, label, "money", 130); }
    public static ReportColumn bool(String key, String label) { return new ReportColumn(key, label, "bool", 90); }
    public static ReportColumn bool(String key, String label, int w) { return new ReportColumn(key, label, "bool", w); }
}
