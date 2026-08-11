package com.uten.imp.features.finance.gl;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.features.finance.report.ReportColumn;
import com.uten.imp.features.finance.report.ReportFacet;
import com.uten.imp.features.finance.report.ReportTableResponse;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 总账报表服务（C3 · 8 张总账报表；数据全部来自 gl_entries + 少量业务表补充列）。
 *
 * <ol>
 *   <li>科目余额表 {@link #trialBalance}：期初/本期借贷/期末，按科目类别定正负向。</li>
 *   <li>附 9 资产负债表 {@link #balanceSheet}：小企业会计准则固定行；期末/年初两列；未分配利润=321+累计损益净额。</li>
 *   <li>附 10 年度利润汇总 {@link #profitAnnual} / 附 11 月度利润表 {@link #profitMonthly}：同一口径行集，
 *       收入=031+032 贷净；成本=041+042 借净；税金=税金；销售费用=销售类 8 科目；管理费用=043 其余；
 *       财务费用=手续费；营业外收入=033 贷净。</li>
 *   <li>附 12 制造费用明细 {@link #manufacturingExpense} / 附 13 管理费用明细 {@link #adminExpense} /
 *       附 14 销售费用明细 {@link #salesExpense}：科目月金额透视（行=项目，列=01..12 月）。</li>
 *   <li>附 16 经营损益表 {@link #operatingPl}：材料费按货品一级类别（DRAW 数量×c_total）+ 工费 + 一般管理费，
 *       占销售比=金额/销售额(031+032 贷净)。</li>
 * </ol>
 *
 * <p>无数据源的项目（直接/间接人工、折旧、社保、招待、维修、交通、装卸、广告等）列占位 NULL，已在各报表注释标明；
 * 附 14 按业务员拆分：费用单据无业务员维度，按费用科目出行（口径注于文档）。</p>
 */
@Service
@RequiredArgsConstructor
public class GlReportService {

    private final EntityManager em;

    /** 销售类费用科目（043 一级子）。 */
    private static final List<String> SALES_FEE_STYLES = List.of(
            "销售费用", "外贸部费用", "OEM部费用", "运费", "快递费用", "淘宝网费用", "慕朵费用", "证书费用");

    // ======================== ① 科目余额表 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse trialBalance(LocalDate from, LocalDate to, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("styleCode", "科目编码", 90),
                ReportColumn.text("styleName", "科目名称", 180),
                ReportColumn.number("level", "级次"),
                ReportColumn.text("category", "类别", 90),
                ReportColumn.money("opening", "期初余额"),
                ReportColumn.money("debit", "本期借方"),
                ReportColumn.money("credit", "本期贷方"),
                ReportColumn.money("closing", "期末余额"));
        var q = em.createNativeQuery("""
                WITH agg AS (
                    SELECT style_id,
                           SUM(CASE WHEN entry_date < :from THEN direction * amount ELSE 0 END) AS opening_net,
                           SUM(CASE WHEN entry_date BETWEEN :from AND :to AND direction = 1 THEN amount ELSE 0 END) AS debit,
                           SUM(CASE WHEN entry_date BETWEEN :from AND :to AND direction = -1 THEN amount ELSE 0 END) AS credit
                    FROM gl_entries WHERE is_deleted = false
                    GROUP BY style_id
                )
                SELECT ps.code, ps.name, ps.level, ps.category,
                       CASE WHEN ps.category IN ('ACCOUNT','EXPENSE') THEN a.opening_net ELSE -a.opening_net END,
                       a.debit, a.credit,
                       CASE WHEN ps.category IN ('ACCOUNT','EXPENSE')
                            THEN a.opening_net + a.debit - a.credit
                            ELSE -(a.opening_net + a.debit - a.credit) END
                FROM agg a JOIN payment_styles ps ON ps.id = a.style_id
                ORDER BY ps.category, ps.code, ps.name
                """);
        q.setParameter("from", from);
        q.setParameter("to", to);
        List<Object[]> rs = NativeQueryResults.objectArrayRows(q);
        List<Map<String, Object>> all = new ArrayList<>(rs.size());
        for (Object[] r : rs) {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("styleCode", norm(r[0]));
            m.put("styleName", norm(r[1]));
            m.put("level", norm(r[2]));
            m.put("category", norm(r[3]));
            m.put("opening", norm(r[4]));
            m.put("debit", norm(r[5]));
            m.put("credit", norm(r[6]));
            m.put("closing", norm(r[7]));
            all.add(m);
        }
        return paginate(cols, all, page, size);
    }

    // ======================== ② 附 9 资产负债表 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse balanceSheet(LocalDate dateTo) {
        LocalDate yearStart = dateTo.withDayOfYear(1);
        LocalDate yearOpen = yearStart.minusDays(1);
        Map<String, BigDecimal> end = balancesByRoot(dateTo);
        Map<String, BigDecimal> open = balancesByRoot(yearOpen);

        List<ReportColumn> cols = List.of(
                ReportColumn.text("item", "项目", 200),
                ReportColumn.text("side", "类别", 110),
                ReportColumn.number("lineNo", "行次"),
                ReportColumn.money("periodEnd", "期末余额"),
                ReportColumn.money("yearStart", "年初余额"));
        List<Map<String, Object>> rows = new ArrayList<>();
        // 资产
        BigDecimal cash1 = sum(end, "/101/", "/102/"), cash0 = sum(open, "/101/", "/102/");
        BigDecimal ar1 = sum(end, "/113/"), ar0 = sum(open, "/113/");
        BigDecimal oar1 = sum(end, "/172/", "/173/"), oar0 = sum(open, "/172/", "/173/");
        BigDecimal inv1 = sum(end, "/123/"), inv0 = sum(open, "/123/");
        BigDecimal prepaid1 = sum(end, "/139/"), prepaid0 = sum(open, "/139/");
        BigDecimal fa1 = sum(end, "/151/"), fa0 = sum(open, "/151/");
        BigDecimal assets1 = cash1.add(ar1).add(oar1).add(inv1).add(prepaid1).add(fa1);
        BigDecimal assets0 = cash0.add(ar0).add(oar0).add(inv0).add(prepaid0).add(fa0);
        // 负债
        BigDecimal ap1 = sum(end, "/203/"), ap0 = sum(open, "/203/");
        BigDecimal tax1 = sum(end, "/221/"), tax0 = sum(open, "/221/");
        BigDecimal oap1 = sum(end, "/204/", "/205/"), oap0 = sum(open, "/204/", "/205/");
        BigDecimal liab1 = ap1.add(tax1).add(oap1), liab0 = ap0.add(tax0).add(oap0);
        // 权益：期初资本 + 未分配利润（/321/ + 累计损益净额）
        BigDecimal eq1 = sum(end, "/301/"), eq0 = sum(open, "/301/");
        BigDecimal profit1 = sum(end, "/321/").add(plNet(dateTo));
        BigDecimal profit0 = sum(open, "/321/").add(plNet(yearOpen));
        BigDecimal equity1 = eq1.add(profit1), equity0 = eq0.add(profit0);

        addBsRow(rows, "货币资金", "资产", 1, cash1, cash0);
        addBsRow(rows, "应收账款", "资产", 4, ar1, ar0);
        addBsRow(rows, "其他应收款", "资产", 8, oar1, oar0);
        addBsRow(rows, "存货", "资产", 9, inv1, inv0);
        addBsRow(rows, "其中:库存商品", "资产", 12, inv1, inv0);
        addBsRow(rows, "其他流动资产(待摊费用)", "资产", 14, prepaid1, prepaid0);
        addBsRow(rows, "流动资产合计", "资产", 15, cash1.add(ar1).add(oar1).add(inv1).add(prepaid1),
                cash0.add(ar0).add(oar0).add(inv0).add(prepaid0));
        addBsRow(rows, "固定资产原价", "资产", 24, fa1, fa0);
        addBsRow(rows, "资产总计", "资产", 29, assets1, assets0);
        addBsRow(rows, "应付账款", "负债和所有者权益", 33, ap1, ap0);
        addBsRow(rows, "应交税费", "负债和所有者权益", 36, tax1, tax0);
        addBsRow(rows, "其他应付款", "负债和所有者权益", 39, oap1, oap0);
        addBsRow(rows, "流动负债合计", "负债和所有者权益", 41, liab1, liab0);
        addBsRow(rows, "实收资本(期初资本)", "负债和所有者权益", 47, eq1, eq0);
        addBsRow(rows, "未分配利润", "负债和所有者权益", 50, profit1, profit0);
        addBsRow(rows, "所有者权益合计", "负债和所有者权益", 51, equity1, equity0);
        addBsRow(rows, "负债和所有者权益总计", "负债和所有者权益", 52, liab1.add(equity1), liab0.add(equity0));
        return new ReportTableResponse(cols, rows, new LinkedHashMap<>(), 1, rows.size(), rows.size(), 1);
    }

    /** 各根科目（/101/ 等）截至 date 的净额，按类别归一化（资产/费用=借正，负债/权益/收入=贷正）。 */
    private Map<String, BigDecimal> balancesByRoot(LocalDate date) {
        var q = em.createNativeQuery("""
                SELECT root.path,
                       CASE WHEN root.category IN ('LIABILITY','EQUITY','INCOME')
                            THEN -SUM(e.direction * e.amount) ELSE SUM(e.direction * e.amount) END
                FROM gl_entries e
                JOIN payment_styles ps ON ps.id = e.style_id
                JOIN payment_styles root ON root.level = 0 AND ps.path LIKE root.path || '%'
                WHERE e.is_deleted = false AND e.entry_date <= :d
                GROUP BY root.path, root.category
                """);
        q.setParameter("d", date);
        List<Object[]> rs = NativeQueryResults.objectArrayRows(q);
        Map<String, BigDecimal> m = new LinkedHashMap<>();
        for (Object[] r : rs) m.put((String) r[0], (BigDecimal) r[1]);
        return m;
    }

    /** 累计损益净额（收入贷净 − 成本费用借净），截至 date。 */
    private BigDecimal plNet(LocalDate date) {
        var q = em.createNativeQuery("""
                SELECT COALESCE(SUM(CASE WHEN ps.category = 'INCOME' THEN -e.direction * e.amount
                                         WHEN ps.category = 'EXPENSE' THEN -e.direction * e.amount
                                         ELSE 0 END), 0)
                FROM gl_entries e JOIN payment_styles ps ON ps.id = e.style_id
                WHERE e.is_deleted = false AND e.entry_date <= :d AND ps.category IN ('INCOME','EXPENSE')
                """);
        q.setParameter("d", date);
        return (BigDecimal) q.getSingleResult();
    }

    private static BigDecimal sum(Map<String, BigDecimal> m, String... paths) {
        BigDecimal t = BigDecimal.ZERO;
        for (String p : paths) t = t.add(m.getOrDefault(p, BigDecimal.ZERO));
        return t;
    }

    private static void addBsRow(List<Map<String, Object>> rows, String item, String side, int lineNo,
                                 BigDecimal end, BigDecimal open) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("item", item);
        m.put("side", side);
        m.put("lineNo", lineNo);
        // 负债/权益类余额已按贷正归一化（balancesByRoot 按类别调号）。
        m.put("periodEnd", end);
        m.put("yearStart", open);
        rows.add(m);
    }

    // ======================== ③④ 附 10/11 利润表 ========================

    /** 利润表行集。months=true → 附 10（12 列）；否则本月+本年累计两列。 */
    private List<Map<String, Object>> profitRows(int year, Integer month) {
        // 科目组 → 每月净额（收入贷净/费用借净）
        Map<String, BigDecimal[]> income = monthlyByPaths(year, "INCOME", new String[]{"/031/", "/032/"});
        Map<String, BigDecimal[]> cost = monthlyByPaths(year, "EXPENSE", new String[]{"/041/", "/042/"});
        Map<String, BigDecimal[]> tax = monthlyByNames(year, "EXPENSE", List.of("税金"));
        Map<String, BigDecimal[]> sales = monthlyByNames(year, "EXPENSE", SALES_FEE_STYLES);
        Map<String, BigDecimal[]> fin = monthlyByNames(year, "EXPENSE", List.of("手续费"));
        Map<String, BigDecimal[]> nonOp = monthlyByPaths(year, "INCOME", new String[]{"/033/"});
        Map<String, BigDecimal[]> admin = monthlyAdmin(year);

        String[] labels = {"一、营业收入", "减：营业成本", "营业税金及附加", "销售费用", "管理费用", "财务费用",
                "二、营业利润", "加：营业外收入", "减：营业外支出", "三、利润总额", "减：所得税费用", "四、净利润"};
        List<Map<String, Object>> rows = new ArrayList<>();
        for (String label : labels) {
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("item", label);
            for (int mi = 1; mi <= 12; mi++) {
                String key = "m" + mi;
                BigDecimal inc = income.getOrDefault(key, new BigDecimal[]{BigDecimal.ZERO})[0];
                BigDecimal cst = cost.getOrDefault(key, new BigDecimal[]{BigDecimal.ZERO})[0];
                BigDecimal tx = tax.getOrDefault(key, new BigDecimal[]{BigDecimal.ZERO})[0];
                BigDecimal sl = sales.getOrDefault(key, new BigDecimal[]{BigDecimal.ZERO})[0];
                BigDecimal ad = admin.getOrDefault(key, new BigDecimal[]{BigDecimal.ZERO})[0];
                BigDecimal fn = fin.getOrDefault(key, new BigDecimal[]{BigDecimal.ZERO})[0];
                BigDecimal no = nonOp.getOrDefault(key, new BigDecimal[]{BigDecimal.ZERO})[0];
                BigDecimal opProfit = inc.subtract(cst).subtract(tx).subtract(sl).subtract(ad).subtract(fn);
                BigDecimal total = opProfit.add(no);
                BigDecimal v = switch (label) {
                    case "一、营业收入" -> inc;
                    case "减：营业成本" -> cst;
                    case "营业税金及附加" -> tx;
                    case "销售费用" -> sl;
                    case "管理费用" -> ad;
                    case "财务费用" -> fn;
                    case "二、营业利润" -> opProfit;
                    case "加：营业外收入" -> no;
                    case "减：营业外支出" -> null;
                    case "三、利润总额" -> total;
                    case "减：所得税费用" -> null;
                    default -> total; // 四、净利润
                };
                row.put(key, v);
            }
            rows.add(row);
        }
        return rows;
    }

    @Transactional(readOnly = true)
    public ReportTableResponse profitAnnual(int year) {
        List<ReportColumn> cols = new ArrayList<>();
        cols.add(ReportColumn.text("item", "项目", 200));
        for (int mi = 1; mi <= 12; mi++) cols.add(ReportColumn.money("m" + mi, String.format("%02d月", mi)));
        List<Map<String, Object>> rows = profitRows(year, null);
        return new ReportTableResponse(cols, rows, new LinkedHashMap<>(), 1, rows.size(), rows.size(), 1);
    }

    @Transactional(readOnly = true)
    public ReportTableResponse profitMonthly(int year, int month) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("item", "项目", 200),
                ReportColumn.money("monthAmount", "本月金额"),
                ReportColumn.money("yearAmount", "本年累计金额"));
        List<Map<String, Object>> annual = profitRows(year, month);
        List<Map<String, Object>> rows = new ArrayList<>();
        for (Map<String, Object> a : annual) {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("item", a.get("item"));
            m.put("monthAmount", a.get("m" + month));
            BigDecimal ytd = null;
            for (int mi = 1; mi <= 12; mi++) {
                Object v = a.get("m" + mi);
                if (v instanceof BigDecimal b) ytd = (ytd == null) ? b : ytd.add(b);
            }
            m.put("yearAmount", ytd);
            rows.add(m);
        }
        return new ReportTableResponse(cols, rows, new LinkedHashMap<>(), 1, rows.size(), rows.size(), 1);
    }

    /** 管理费用 = 043 一级子中 非销售/税金/财务 的科目月净额。 */
    private Map<String, BigDecimal[]> monthlyAdmin(int year) {
        var q = em.createNativeQuery("""
                SELECT to_char(e.entry_date,'MM') AS mm, SUM(e.direction * e.amount)
                FROM gl_entries e JOIN payment_styles ps ON ps.id = e.style_id
                WHERE e.is_deleted = false AND ps.category = 'EXPENSE'
                  AND ps.path LIKE '/043/%'
                  AND ps.name NOT IN (""" + inList(adminExcludes()) + """
                  )
                  AND EXTRACT(YEAR FROM e.entry_date) = :y
                GROUP BY 1
                """);
        q.setParameter("y", year);
        return toMonthMap(NativeQueryResults.objectArrayRows(q));
    }

    /** 按根 path（/031/ 等）聚合月净额：INCOME 取贷净（-dir），EXPENSE 取借净（+dir）。 */
    private Map<String, BigDecimal[]> monthlyByPaths(int year, String category, String[] paths) {
        var q = em.createNativeQuery("""
                SELECT to_char(e.entry_date,'MM') AS mm,
                       SUM(CASE WHEN :cat = 'INCOME' THEN -e.direction * e.amount ELSE e.direction * e.amount END)
                FROM gl_entries e
                JOIN payment_styles ps ON ps.id = e.style_id
                JOIN payment_styles root ON root.level = 0 AND ps.path LIKE root.path || '%'
                WHERE e.is_deleted = false AND ps.category = :cat AND root.path IN (""" + inList(List.of(paths)) + """
                )
                  AND EXTRACT(YEAR FROM e.entry_date) = :y
                GROUP BY 1
                """);
        q.setParameter("cat", category);
        q.setParameter("y", year);
        return toMonthMap(NativeQueryResults.objectArrayRows(q));
    }

    /** 按科目名（EXPENSE）聚合月借净。 */
    private Map<String, BigDecimal[]> monthlyByNames(int year, String category, List<String> names) {
        var q = em.createNativeQuery("""
                SELECT to_char(e.entry_date,'MM') AS mm, SUM(e.direction * e.amount)
                FROM gl_entries e JOIN payment_styles ps ON ps.id = e.style_id
                WHERE e.is_deleted = false AND ps.category = :cat AND ps.name IN (""" + inList(names) + """
                )
                  AND EXTRACT(YEAR FROM e.entry_date) = :y
                GROUP BY 1
                """);
        q.setParameter("cat", category);
        q.setParameter("y", year);
        return toMonthMap(NativeQueryResults.objectArrayRows(q));
    }

    /** 常量名集合 → SQL IN 字面量（仅代码内置科目名，无用户输入）。 */
    private static String inList(List<String> names) {
        StringBuilder sb = new StringBuilder();
        for (String n : names) {
            if (sb.length() > 0) sb.append(',');
            sb.append('\'').append(n.replace("'", "''")).append('\'');
        }
        return sb.toString();
    }

    private static Map<String, BigDecimal[]> toMonthMap(List<Object[]> rs) {
        Map<String, BigDecimal[]> m = new LinkedHashMap<>();
        for (Object[] r : rs) m.put("m" + Integer.parseInt(((String) r[0]).trim()), new BigDecimal[]{(BigDecimal) r[1]});
        return m;
    }

    private static List<String> adminExcludes() {
        List<String> all = new ArrayList<>(SALES_FEE_STYLES);
        all.add("税金");
        all.add("手续费");
        return all;
    }

    // ======================== ⑤⑥⑦ 附 12/13/14 费用明细（行=项目 × 列=月） ========================

    @Transactional(readOnly = true)
    public ReportTableResponse manufacturingExpense(int year) {
        // 行：label → 科目名集合（null=业务表取数占位）
        LinkedHashMap<String, List<String>> defs = new LinkedHashMap<>();
        defs.put("生产产值", null);            // FINISHED_IN 流水金额（下方单独查）
        defs.put("直接人工", null);
        defs.put("间接人工", null);
        defs.put("资产折旧", null);
        defs.put("模具维修", List.of("模具费用", "制作模具"));
        defs.put("物料消耗", List.of("材料费用"));
        defs.put("其他费用", List.of("其它费用"));
        defs.put("水电费", List.of("水费", "电费"));
        defs.put("加工费", null);              // 委外进仓金额（下方单独查）
        defs.put("品质部", List.of("品质部", "品质部费用"));
        defs.put("仓储部门", List.of("仓库费用"));
        defs.put("安装车间", List.of("安装车间费用"));
        defs.put("注塑车间", List.of("注塑部费用"));
        defs.put("轨道车间", List.of("轨道车间费用"));
        defs.put("铜柱车间", List.of("铜粒车间费用"));
        defs.put("酸洗车间", List.of("酸洗车间"));
        Map<String, Map<String, BigDecimal[]>> data = new LinkedHashMap<>();
        for (var e : defs.entrySet()) {
            if (e.getValue() != null) data.put(e.getKey(), monthlyByNames(year, "EXPENSE", e.getValue()));
        }
        data.put("生产产值", finishedInMonthly(year));
        data.put("加工费", subcontractMonthly(year));
        return pivotTable("制造费用项目", defs.keySet().stream().toList(), data);
    }

    @Transactional(readOnly = true)
    public ReportTableResponse adminExpense(int year) {
        LinkedHashMap<String, List<String>> defs = new LinkedHashMap<>();
        defs.put("销售额", null);              // 031 贷净
        defs.put("厂房及成品仓租赁费", List.of("房租"));
        defs.put("工资", List.of("工资费用"));
        defs.put("餐费", List.of("餐费", "饭堂费用"));
        defs.put("福利费", null);
        defs.put("社保费", null);
        defs.put("办公费", List.of("办公费用"));
        defs.put("通迅费", List.of("电话费"));
        defs.put("交通费", null);
        defs.put("招待费", null);
        defs.put("维修费", null);
        defs.put("汽车费", List.of("汽车费用"));
        defs.put("证书费", List.of("证书费用"));
        defs.put("快递费", List.of("快递费用"));
        defs.put("设计费", List.of("设计费用"));
        defs.put("劳动用品", List.of("劳动用品"));
        defs.put("人事费用", List.of("人事部费用"));
        defs.put("其它费用", List.of("其它费用"));
        Map<String, Map<String, BigDecimal[]>> data = new LinkedHashMap<>();
        for (var e : defs.entrySet()) {
            if (e.getValue() != null) data.put(e.getKey(), monthlyByNames(year, "EXPENSE", e.getValue()));
        }
        data.put("销售额", monthlyByPaths(year, "INCOME", new String[]{"/031/"}));
        return pivotTable("管理费用项目", defs.keySet().stream().toList(), data);
    }

    @Transactional(readOnly = true)
    public ReportTableResponse salesExpense(int year) {
        List<String> labels = new ArrayList<>(SALES_FEE_STYLES);
        Map<String, Map<String, BigDecimal[]>> data = new LinkedHashMap<>();
        for (String s : labels) data.put(s, monthlyByNames(year, "EXPENSE", List.of(s)));
        return pivotTable("销售费用项目", labels, data);
    }

    /** 通用透视表：行=labels，列=item+01..12 月。 */
    private static ReportTableResponse pivotTable(String itemLabel, List<String> labels,
                                                  Map<String, Map<String, BigDecimal[]>> data) {
        List<ReportColumn> cols = new ArrayList<>();
        cols.add(ReportColumn.text("item", itemLabel, 180));
        for (int mi = 1; mi <= 12; mi++) cols.add(ReportColumn.money("m" + mi, String.format("%02d月", mi)));
        List<Map<String, Object>> rows = new ArrayList<>();
        for (String label : labels) {
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("item", label);
            Map<String, BigDecimal[]> mm = data.get(label);
            for (int mi = 1; mi <= 12; mi++) {
                row.put("m" + mi, mm == null ? null : mm.getOrDefault("m" + mi, new BigDecimal[]{null})[0]);
            }
            rows.add(row);
        }
        return new ReportTableResponse(cols, rows, new LinkedHashMap<>(), 1, rows.size(), rows.size(), 1);
    }

    /** 生产产值：成品入库流水月金额（movement_type=13, amount_local）。 */
    private Map<String, BigDecimal[]> finishedInMonthly(int year) {
        var q = em.createNativeQuery("""
                SELECT to_char(transaction_date,'MM') AS mm, SUM(amount_local)
                FROM stock_movements
                WHERE movement_type = 13 AND EXTRACT(YEAR FROM transaction_date) = :y
                GROUP BY 1
                """);
        q.setParameter("y", year);
        return toMonthMap(NativeQueryResults.objectArrayRows(q));
    }

    /** 委外加工费：委外进仓行月金额（单头 total_local 老库全 0，取行 amount_local 合计）。 */
    private Map<String, BigDecimal[]> subcontractMonthly(int year) {
        var q = em.createNativeQuery("""
                SELECT to_char(d.bill_date,'MM') AS mm, SUM(i.amount_local)
                FROM subcontract_receipt_items i
                JOIN subcontract_receipts d ON d.id = i.receipt_id
                WHERE d.status = 1 AND d.is_deleted = false AND i.is_deleted = false
                  AND EXTRACT(YEAR FROM d.bill_date) = :y
                GROUP BY 1
                """);
        q.setParameter("y", year);
        return toMonthMap(NativeQueryResults.objectArrayRows(q));
    }

    // ======================== ⑧ 附 16 经营损益表 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse operatingPl(int year, int month) {
        LocalDate from = LocalDate.of(year, month, 1);
        LocalDate to = from.plusMonths(1).minusDays(1);
        // 销售额基数 = 031+032 贷净（模板「应收账款」行）
        var baseQ = em.createNativeQuery("""
                SELECT COALESCE(SUM(-e.direction * e.amount),0)
                FROM gl_entries e JOIN payment_styles ps ON ps.id = e.style_id
                JOIN payment_styles root ON root.level = 0 AND ps.path LIKE root.path || '%'
                WHERE e.is_deleted = false AND ps.category='INCOME' AND root.path IN ('/031/','/032/')
                  AND e.entry_date BETWEEN :from AND :to
                """);
        baseQ.setParameter("from", from);
        baseQ.setParameter("to", to);
        BigDecimal base = (BigDecimal) baseQ.getSingleResult();

        List<ReportColumn> cols = List.of(
                ReportColumn.text("category", "项目分类", 110),
                ReportColumn.text("sub", "分项", 120),
                ReportColumn.text("item", "具体项目", 170),
                ReportColumn.money("amount", "金额"),
                ReportColumn.number("salesRatio", "占销售比%"));

        List<Map<String, Object>> rows = new ArrayList<>();
        addOpRow(rows, "应收账款", "", "", base, base);

        // 材料费：DRAW 月耗用（qty×c_total）按货品一级类别（material_categories 根的直下）
        var matQ = em.createNativeQuery("""
                SELECT COALESCE(mc.name,'未分类'), SUM(m.qty * COALESCE(g.c_total,0))
                FROM stock_movements m
                JOIN goods g ON g.id = m.goods_id
                LEFT JOIN material_categories leaf ON leaf.id = g.category_id
                LEFT JOIN material_categories mc ON mc.id = COALESCE(leaf.parent_id, leaf.id)
                WHERE m.source_doc_type='STOCK_DOC' AND m.movement_type = 5
                  AND m.transaction_date BETWEEN :from AND :to
                GROUP BY 1 HAVING SUM(m.qty * COALESCE(g.c_total,0)) <> 0
                ORDER BY 2 DESC
                """);
        matQ.setParameter("from", from);
        matQ.setParameter("to", to);
        List<Object[]> mats = NativeQueryResults.objectArrayRows(matQ);
        BigDecimal matTotal = BigDecimal.ZERO;
        for (Object[] r : mats) {
            BigDecimal amt = (BigDecimal) r[1];
            matTotal = matTotal.add(amt);
            addOpRow(rows, "材料费", "主材", (String) r[0], amt, base);
        }
        addOpRow(rows, "材料费", "材料费合计", "", matTotal, base);

        // 工费
        BigDecimal meal = styleNet("EXPENSE", List.of("餐费", "饭堂费用"), from, to);
        BigDecimal sub = subcontractMonth(year, month);
        addOpRow(rows, "工费", "劳务费", "直接人员工资", null, base);
        addOpRow(rows, "工费", "劳务费", "间接人员工资", null, base);
        addOpRow(rows, "工费", "劳务费", "人员福利+社保+餐费", meal, base);
        addOpRow(rows, "工费", "劳务费", "委外加工费", sub, base);
        addOpRow(rows, "工费", "工费合计", "", nz(meal).add(nz(sub)), base);

        // 一般管理费（模板行序；无数据源 NULL）
        LinkedHashMap<String, List<String>> adminDefs = new LinkedHashMap<>();
        adminDefs.put("厂房及成品仓租金", List.of("房租"));
        adminDefs.put("宿舍租金", null);
        adminDefs.put("电费", List.of("电费"));
        adminDefs.put("水费", List.of("水费"));
        adminDefs.put("设备折旧费", null);
        adminDefs.put("模具折旧费", null);
        adminDefs.put("广告费", null);
        adminDefs.put("物流费", List.of("运费"));
        adminDefs.put("装卸费", null);
        adminDefs.put("快递费", List.of("快递费用"));
        adminDefs.put("物业管理费", null);
        adminDefs.put("办公费", List.of("办公费用"));
        adminDefs.put("电话费", List.of("电话费"));
        adminDefs.put("维修费", null);
        adminDefs.put("设计费", List.of("设计费用"));
        adminDefs.put("税收手续费", List.of("税金"));
        adminDefs.put("账务处理费", null);
        adminDefs.put("招待费", null);
        adminDefs.put("交通费", null);
        adminDefs.put("检测费", null);
        adminDefs.put("报关费", null);
        adminDefs.put("财务费用", List.of("手续费"));
        adminDefs.put("其他费", List.of("其它费用"));
        String[] subs = {"场地费用分摊", "场地费用分摊", "能耗", "能耗", "设备费用", "设备费用", "品牌支撑分摊",
                "运输费分摊", "运输费分摊", "运输费分摊", "发展支撑分摊", "发展支撑分摊", "发展支撑分摊",
                "发展支撑分摊", "发展支撑分摊", "发展支撑分摊", "发展支撑分摊", "发展支撑分摊", "发展支撑分摊",
                "发展支撑分摊", "发展支撑分摊", "发展支撑分摊", "发展支撑分摊"};
        int i = 0;
        BigDecimal adminTotal = BigDecimal.ZERO;
        for (var e : adminDefs.entrySet()) {
            BigDecimal amt = e.getValue() == null ? null : styleNet("EXPENSE", e.getValue(), from, to);
            if (amt != null) adminTotal = adminTotal.add(amt);
            addOpRow(rows, "一般管理费", subs[i++], e.getKey(), amt, base);
        }
        addOpRow(rows, "一般管理费", "管理费合计", "", adminTotal, base);
        return new ReportTableResponse(cols, rows, new LinkedHashMap<>(), 1, rows.size(), rows.size(), 1);
    }

    private BigDecimal subcontractMonth(int year, int month) {
        var q = em.createNativeQuery("""
                SELECT COALESCE(SUM(i.amount_local),0) FROM subcontract_receipt_items i
                JOIN subcontract_receipts d ON d.id = i.receipt_id
                WHERE d.status=1 AND d.is_deleted=false AND i.is_deleted=false
                  AND to_char(d.bill_date,'YYYY-MM') = :p
                """);
        q.setParameter("p", String.format("%04d-%02d", year, month));
        return (BigDecimal) q.getSingleResult();
    }

    /** 指定类别+科目名集合的期间净额（EXPENSE 借净 / INCOME 贷净）。 */
    private BigDecimal styleNet(String category, List<String> names, LocalDate from, LocalDate to) {
        var q = em.createNativeQuery("""
                SELECT COALESCE(SUM(CASE WHEN :cat='INCOME' THEN -e.direction*e.amount ELSE e.direction*e.amount END),0)
                FROM gl_entries e JOIN payment_styles ps ON ps.id = e.style_id
                WHERE e.is_deleted = false AND ps.category = :cat AND ps.name IN (""" + inList(names) + """
                )
                  AND e.entry_date BETWEEN :from AND :to
                """);
        q.setParameter("cat", category);
        q.setParameter("from", from);
        q.setParameter("to", to);
        return (BigDecimal) q.getSingleResult();
    }

    private static void addOpRow(List<Map<String, Object>> rows, String cat, String sub, String item,
                                 BigDecimal amount, BigDecimal base) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("category", cat);
        m.put("sub", sub);
        m.put("item", item);
        m.put("amount", amount);
        m.put("salesRatio", (amount == null || base == null || base.signum() == 0) ? null
                : amount.multiply(new BigDecimal("100")).divide(base, 2, RoundingMode.HALF_UP));
        rows.add(m);
    }

    private static BigDecimal nz(BigDecimal v) { return v == null ? BigDecimal.ZERO : v; }

    // ======================== 工具 ========================

    private static ReportTableResponse paginate(List<ReportColumn> cols, List<Map<String, Object>> all,
                                                int page, int size) {
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 500);
        int from = Math.min((safePage - 1) * safeSize, all.size());
        int to = Math.min(from + safeSize, all.size());
        int totalPages = safeSize == 0 ? 0 : (int) ((all.size() + safeSize - 1) / safeSize);
        Map<String, List<ReportFacet>> facets = new LinkedHashMap<>();
        return new ReportTableResponse(cols, all.subList(from, to), facets, safePage, safeSize, all.size(), totalPages);
    }

    private static Object norm(Object v) {
        if (v == null) return null;
        if (v instanceof java.sql.Date d) return d.toLocalDate().toString();
        if (v instanceof java.sql.Timestamp t) return t.toLocalDateTime().toLocalDate().toString();
        if (v instanceof BigDecimal || v instanceof Boolean || v instanceof Number) return v;
        if (v instanceof UUID u) return u.toString();
        return v.toString();
    }
}
