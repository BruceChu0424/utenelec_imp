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
        AMORTIZATION,
        /** 成品入库流水金额(业务事实, 不需配置)。 */
        FINISHED_IN,
        /** 委外进仓金额(业务事实, 不需配置)。 */
        SUBCONTRACT,
        /** 主营收入(031 根科目贷净, 不需配置)。 */
        SALES_INCOME
    }

    public boolean configurable() {
        return source == Source.STYLES || source == Source.PAYROLL || source == Source.DEPRECIATION || source == Source.AMORTIZATION;
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

    /** Captions and original order are read from the single reviewed template contract. */
    static final List<GlReportLine> MANUFACTURING = FinanceExpenseTemplateCatalog.lines("manufacturingExpense");
    static final List<GlReportLine> ADMIN = FinanceExpenseTemplateCatalog.lines("adminExpense");
    // Retained only as migration/settings targets: nonzero legacy bindings make the new total pending.
    static final List<GlReportLine> LEGACY_MANUFACTURING = List.of(styles("MFG_PICKLING", "酸洗车间"));
    static final GlReportLine MANUFACTURING_LABOR_CONTROL = styles("MFG_LABOR_CONTROL", "职工薪酬费");
    static final List<GlReportLine> LEGACY_ADMIN = List.of(styles("ADM_CERT", "证书费"),styles("ADM_EXPRESS", "快递费"),
            styles("ADM_LABOR_SUPPLY", "劳动用品"),styles("ADM_HR", "人事费用"));
    static final GlReportLine OP_LABOR_DIRECT = new GlReportLine("LABOR_DIRECT", "直接人员工资", Source.PAYROLL);
    static final GlReportLine OP_LABOR_INDIRECT = new GlReportLine("LABOR_INDIRECT", "间接人员工资", Source.PAYROLL);
    static final GlReportLine OP_MEAL = styles("OP_MEAL", "人员福利+社保+餐费");
    static final GlReportLine OP_SUBCONTRACT = styles("OP_SUBCONTRACT", "委外加工费");
    static final List<GlReportLine> OPERATING_MATERIALS = FinanceExpenseTemplateCatalog.operatingRows().stream()
            .filter(row->!row.total()&&row.sourceRow()>=4&&row.sourceRow()<=40)
            .map(FinanceExpenseTemplateCatalog::operatingLine).toList();
    static final Map<GlReportLine,String> OPERATING_ADMIN = operatingAdmin();
    private static Map<GlReportLine,String> operatingAdmin() {
        Map<GlReportLine,String> rows=new LinkedHashMap<>();
        FinanceExpenseTemplateCatalog.operatingRows().stream().filter(row->!row.total()&&row.sourceRow()>=48&&row.sourceRow()<=89)
                .forEach(row->rows.put(FinanceExpenseTemplateCatalog.operatingLine(row),row.sub()));
        return java.util.Collections.unmodifiableMap(rows);
    }
    static List<GlReportLine> operatingLines() {
        var result=new java.util.ArrayList<>(OPERATING_MATERIALS);
        result.addAll(List.of(OP_LABOR_DIRECT,OP_LABOR_INDIRECT,OP_MEAL,OP_SUBCONTRACT));result.addAll(OPERATING_ADMIN.keySet());return List.copyOf(result);
    }
    static String sheetFor(String key) {
        if(MANUFACTURING_LABOR_CONTROL.key().equals(key)||MANUFACTURING.stream().anyMatch(l->l.key().equals(key))||LEGACY_MANUFACTURING.stream().anyMatch(l->l.key().equals(key)))return "MANUFACTURING";
        if(ADMIN.stream().anyMatch(l->l.key().equals(key))||LEGACY_ADMIN.stream().anyMatch(l->l.key().equals(key)))return "ADMIN";
        if(operatingLines().stream().anyMatch(l->l.key().equals(key)))return "OPERATING";
        return null;
    }
    static boolean costExpenseLine(String key){return key.startsWith("MFG_")||key.startsWith("OP_");}
    /** 全部可配置行(按 key 去重), 供报表设置页列出。 */
    public static List<GlReportLine> configurableLines() {
        Map<String, GlReportLine> byKey = new LinkedHashMap<>();
        java.util.stream.Stream.of(
                        MANUFACTURING.stream(), ADMIN.stream(), LEGACY_MANUFACTURING.stream(),java.util.stream.Stream.of(MANUFACTURING_LABOR_CONTROL), LEGACY_ADMIN.stream(), OPERATING_MATERIALS.stream(),
                        java.util.stream.Stream.of(SALES_FEE, PL_TAX, PL_FINANCE, OP_MEAL,OP_SUBCONTRACT),
                        OPERATING_ADMIN.keySet().stream())
                .flatMap(stream -> stream)
                .filter(GlReportLine::configurable)
                .forEach(line -> byKey.putIfAbsent(line.key(), line));
        FinancialStatementCatalog.all().stream().filter(FinancialStatementCatalog.Line::direct)
                .forEach(line -> byKey.putIfAbsent(line.key(), styles(line.key(),
                        (line.sheet().equals("BALANCE") ? "资产负债表 " : "利润表 ")+line.number()+" · "+line.label())));
        return List.copyOf(byKey.values());
    }

    public static GlReportLine configurable(String key) {
        return configurableLines().stream().filter(line -> line.key().equals(key)).findFirst().orElse(null);
    }

    /** 各张表的行(附 12、附 13、利润表的税金/销售费用/财务费用、附 16)。同一张表里一个科目只能归一行。 */
    static List<List<GlReportLine>> sheets() {
        List<GlReportLine> operating = new java.util.ArrayList<>(List.of(OP_LABOR_DIRECT, OP_LABOR_INDIRECT, OP_MEAL,OP_SUBCONTRACT));
        operating.addAll(OPERATING_MATERIALS); operating.addAll(OPERATING_ADMIN.keySet());
        var manufacturing=new java.util.ArrayList<>(MANUFACTURING);manufacturing.addAll(LEGACY_MANUFACTURING);manufacturing.add(MANUFACTURING_LABOR_CONTROL);
        var admin=new java.util.ArrayList<>(ADMIN);admin.addAll(LEGACY_ADMIN);
        return List.of(List.copyOf(manufacturing), List.copyOf(admin), List.of(PL_TAX, SALES_FEE, PL_FINANCE), List.copyOf(operating));
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
        siblings.addAll(FinancialStatementCatalog.siblings(key));
        // The shared labor pool already feeds both operating payroll rows. It cannot
        // also appear as another operating fee, even though the settings span sheets.
        if(key.equals(MANUFACTURING_LABOR_CONTROL.key()))operatingLines().stream().filter(l->"STYLE".equals(l.bindingKind())).forEach(l->siblings.add(l.key()));
        else if(operatingLines().stream().anyMatch(l->l.key().equals(key)&&"STYLE".equals(l.bindingKind())))siblings.add(MANUFACTURING_LABOR_CONTROL.key());
        return siblings;
    }
}
