package com.uten.imp.features.finance.gl;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 总账附表/经营损益表的报表行目录(ADR-112 / overhaul-gap-03)。
 *
 * <p>行的清单、顺序与取数来源由这里定义; 行绑定哪些科目或部门存放在
 * {@code finance_report_line_bindings}, 由财务在报表设置里维护。没有绑定的行在报表上标注
 * 「未配置科目」(人工行为「未配置部门」), 不再显示空值, 也不再按科目名猜。
 */
public record GlReportLine(String key, String label, Source source) {

    /** 取数来源。 */
    public enum Source {
        /** 绑定科目的总账发生额(费用借净)。 */
        STYLES,
        /** 绑定部门(含下级)已审核工资单的应发合计。 */
        PAYROLL,
        /** 绑定费用科目上的固定资产折旧事实(公司账簿、有效的正常折旧)。 */
        DEPRECIATION,
        /** 成品入库流水金额(业务事实, 不需配置)。 */
        FINISHED_IN,
        /** 委外进仓金额(业务事实, 不需配置)。 */
        SUBCONTRACT,
        /** 主营收入(031 根科目贷净, 不需配置)。 */
        SALES_INCOME
    }

    public boolean configurable() {
        return source == Source.STYLES || source == Source.PAYROLL || source == Source.DEPRECIATION;
    }

    /** 绑定目标种类: 人工行绑部门, 其余可配置行绑科目。 */
    public String bindingKind() {
        return source == Source.PAYROLL ? "DEPARTMENT" : "STYLE";
    }

    private static GlReportLine styles(String key, String label) {
        return new GlReportLine(key, label, Source.STYLES);
    }

    // 两张表共用的人工与销售费用行。
    static final GlReportLine LABOR_DIRECT = new GlReportLine("LABOR_DIRECT", "直接人工", Source.PAYROLL);
    static final GlReportLine LABOR_INDIRECT = new GlReportLine("LABOR_INDIRECT", "间接人工", Source.PAYROLL);
    static final GlReportLine SALES_FEE = styles("SALES_FEE", "销售费用");
    static final GlReportLine PL_TAX = styles("PL_TAX", "营业税金及附加");
    static final GlReportLine PL_FINANCE = styles("PL_FINANCE", "财务费用");

    /** 附 12 制造费用明细。 */
    static final List<GlReportLine> MANUFACTURING = List.of(
            new GlReportLine("MFG_OUTPUT", "生产产值", Source.FINISHED_IN),
            LABOR_DIRECT,
            LABOR_INDIRECT,
            new GlReportLine("MFG_DEPRECIATION", "资产折旧", Source.DEPRECIATION),
            styles("MFG_MOULD_REPAIR", "模具维修"),
            styles("MFG_MATERIAL", "物料消耗"),
            styles("MFG_OTHER", "其他费用"),
            styles("MFG_UTILITIES", "水电费"),
            new GlReportLine("MFG_SUBCONTRACT", "加工费", Source.SUBCONTRACT),
            styles("MFG_QC", "品质部"),
            styles("MFG_WAREHOUSE", "仓储部门"),
            styles("MFG_ASSEMBLY", "安装车间"),
            styles("MFG_INJECTION", "注塑车间"),
            styles("MFG_RAIL", "轨道车间"),
            styles("MFG_COPPER", "铜柱车间"),
            styles("MFG_PICKLING", "酸洗车间"));

    /** 附 13 管理费用明细。 */
    static final List<GlReportLine> ADMIN = List.of(
            new GlReportLine("ADM_SALES", "销售额", Source.SALES_INCOME),
            styles("ADM_RENT", "厂房及成品仓租赁费"),
            styles("ADM_SALARY", "工资"),
            styles("ADM_MEAL", "餐费"),
            styles("ADM_WELFARE", "福利费"),
            styles("ADM_SOCIAL", "社保费"),
            styles("ADM_OFFICE", "办公费"),
            styles("ADM_PHONE", "通迅费"),
            styles("ADM_TRAVEL", "交通费"),
            styles("ADM_ENTERTAIN", "招待费"),
            styles("ADM_REPAIR", "维修费"),
            styles("ADM_VEHICLE", "汽车费"),
            styles("ADM_CERT", "证书费"),
            styles("ADM_EXPRESS", "快递费"),
            styles("ADM_DESIGN", "设计费"),
            styles("ADM_LABOR_SUPPLY", "劳动用品"),
            styles("ADM_HR", "人事费用"),
            styles("ADM_OTHER", "其它费用"));

    /** 附 16 经营损益表 · 工费(人工取工资单, 餐费取科目, 委外取进仓)。 */
    static final GlReportLine OP_LABOR_DIRECT = new GlReportLine("LABOR_DIRECT", "直接人员工资", Source.PAYROLL);
    static final GlReportLine OP_LABOR_INDIRECT = new GlReportLine("LABOR_INDIRECT", "间接人员工资", Source.PAYROLL);
    static final GlReportLine OP_MEAL = styles("OP_MEAL", "人员福利+社保+餐费");

    /** 附 16 经营损益表 · 一般管理费(行, 分项)。 */
    static final Map<GlReportLine, String> OPERATING_ADMIN = operatingAdmin();

    private static Map<GlReportLine, String> operatingAdmin() {
        Map<GlReportLine, String> rows = new LinkedHashMap<>();
        rows.put(styles("OP_RENT", "厂房及成品仓租金"), "场地费用分摊");
        rows.put(styles("OP_DORM_RENT", "宿舍租金"), "场地费用分摊");
        rows.put(styles("OP_ELECTRICITY", "电费"), "能耗");
        rows.put(styles("OP_WATER", "水费"), "能耗");
        rows.put(new GlReportLine("OP_DEPRECIATION_EQUIPMENT", "设备折旧费", Source.DEPRECIATION), "设备费用");
        rows.put(new GlReportLine("OP_DEPRECIATION_MOULD", "模具折旧费", Source.DEPRECIATION), "设备费用");
        rows.put(styles("OP_ADVERTISING", "广告费"), "品牌支撑分摊");
        rows.put(styles("OP_LOGISTICS", "物流费"), "运输费分摊");
        rows.put(styles("OP_HANDLING", "装卸费"), "运输费分摊");
        rows.put(styles("OP_EXPRESS", "快递费"), "运输费分摊");
        rows.put(styles("OP_PROPERTY", "物业管理费"), "发展支撑分摊");
        rows.put(styles("OP_OFFICE", "办公费"), "发展支撑分摊");
        rows.put(styles("OP_PHONE", "电话费"), "发展支撑分摊");
        rows.put(styles("OP_REPAIR", "维修费"), "发展支撑分摊");
        rows.put(styles("OP_DESIGN", "设计费"), "发展支撑分摊");
        rows.put(styles("OP_TAX_FEE", "税收手续费"), "发展支撑分摊");
        rows.put(styles("OP_ACCOUNTING", "账务处理费"), "发展支撑分摊");
        rows.put(styles("OP_ENTERTAIN", "招待费"), "发展支撑分摊");
        rows.put(styles("OP_TRAVEL", "交通费"), "发展支撑分摊");
        rows.put(styles("OP_INSPECTION", "检测费"), "发展支撑分摊");
        rows.put(styles("OP_CUSTOMS", "报关费"), "发展支撑分摊");
        rows.put(styles("OP_FINANCE", "财务费用"), "发展支撑分摊");
        rows.put(styles("OP_OTHER", "其他费"), "发展支撑分摊");
        return java.util.Collections.unmodifiableMap(rows);
    }

    /** 全部可配置行(按 key 去重), 供报表设置页列出。 */
    public static List<GlReportLine> configurableLines() {
        Map<String, GlReportLine> byKey = new LinkedHashMap<>();
        java.util.stream.Stream.of(
                        MANUFACTURING.stream(), ADMIN.stream(),
                        java.util.stream.Stream.of(SALES_FEE, PL_TAX, PL_FINANCE, OP_MEAL),
                        OPERATING_ADMIN.keySet().stream())
                .flatMap(stream -> stream)
                .filter(GlReportLine::configurable)
                .forEach(line -> byKey.putIfAbsent(line.key(), line));
        return List.copyOf(byKey.values());
    }

    public static GlReportLine configurable(String key) {
        return configurableLines().stream().filter(line -> line.key().equals(key)).findFirst().orElse(null);
    }

    /** 各张表的行(附 12、附 13、利润表的税金/销售费用/财务费用、附 16)。同一张表里一个科目只能归一行。 */
    static List<List<GlReportLine>> sheets() {
        List<GlReportLine> operating = new java.util.ArrayList<>(List.of(OP_LABOR_DIRECT, OP_LABOR_INDIRECT, OP_MEAL));
        operating.addAll(OPERATING_ADMIN.keySet());
        return List.of(MANUFACTURING, ADMIN, List.of(PL_TAX, SALES_FEE, PL_FINANCE), List.copyOf(operating));
    }

    /**
     * 与该行同在一张表里、同样绑科目的其它行(科目行与折旧行): 一个科目同时归到其中两行, 合计会重复
     * (折旧本身也以同一费用科目过进总账)。
     */
    public static java.util.Set<String> styleSiblings(String key) {
        java.util.Set<String> siblings = new java.util.TreeSet<>();
        for (List<GlReportLine> sheet : sheets()) {
            if (sheet.stream().noneMatch(line -> line.key().equals(key))) continue;
            sheet.stream().filter(GlReportLine::configurable)
                    .filter(line -> "STYLE".equals(line.bindingKind()) && !line.key().equals(key))
                    .forEach(line -> siblings.add(line.key()));
        }
        return siblings;
    }
}
