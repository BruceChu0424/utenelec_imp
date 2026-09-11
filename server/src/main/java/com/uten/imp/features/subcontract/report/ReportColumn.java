package com.uten.imp.features.subcontract.report;

/**
 * 报表列定义（驱动前端 MasterDataTableView 动态建列）。与 purchase.report.ReportColumn 同构，
 * 复制一份避免跨 feature 依赖。
 *
 * @param key   列键（= SQL SELECT 别名 = 行 Map 的 key = facet 的 key）
 * @param label 列标题（中文）
 * @param type  text / date / number / money / bool / int / style —— 前端按类型格式化与对齐
 * @param width 建议列宽（px），可空
 */
public record ReportColumn(String key, String label, String type, Integer width,
                           String totalLabel, String totalGroupKey) {

    /** 兼容构造：不参与合计的列沿用原 4 参签名（所有既有工厂方法走这里）。 */
    public ReportColumn(String key, String label, String type, Integer width) {
        this(key, label, type, width, null, null);
    }

    /**
     * 声明本列参与「表格下方合计」，由服务端在<b>整个结果集</b>上聚合（见 ReportTotalsCalculator）。
     *
     * <p>{@code groupKey} 指向同一行里的单位名/币种名列：数量按单位分组、金额按币种分组，
     * <b>不同单位/币种绝不相加</b>；传 null 表示该报表没有分组维度，只出一个总数。
     *
     * <p>只对「可加」的列声明：数量/金额/重量可以；单价、库存快照、比率这类列相加无意义，不要声明。
     */
    public ReportColumn totaled(String totalLabel, String groupKey) {
        return new ReportColumn(key, label, type, width, totalLabel, groupKey);
    }

    /** 无分组维度的合计（整份报表只出一个总数）。 */
    public ReportColumn totaled(String totalLabel) {
        return totaled(totalLabel, null);
    }

    public static ReportColumn text(String key, String label) { return new ReportColumn(key, label, "text", null); }
    public static ReportColumn text(String key, String label, int w) { return new ReportColumn(key, label, "text", w); }
    public static ReportColumn date(String key, String label) { return new ReportColumn(key, label, "date", 120); }
    public static ReportColumn date(String key, String label, int w) { return new ReportColumn(key, label, "date", w); }
    public static ReportColumn number(String key, String label) { return new ReportColumn(key, label, "number", 110); }
    public static ReportColumn number(String key, String label, int w) { return new ReportColumn(key, label, "number", w); }
    public static ReportColumn money(String key, String label) { return new ReportColumn(key, label, "money", 130); }
    public static ReportColumn money(String key, String label, int w) { return new ReportColumn(key, label, "money", w); }
    public static ReportColumn bool(String key, String label) { return new ReportColumn(key, label, "bool", 90); }
    public static ReportColumn bool(String key, String label, int w) { return new ReportColumn(key, label, "bool", w); }
}
