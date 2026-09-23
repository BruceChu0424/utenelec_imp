package com.uten.imp.features.finance.gl;

import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.features.finance.report.ReportColumn;
import com.uten.imp.features.finance.report.ReportFacet;
import com.uten.imp.features.finance.report.ReportTableResponse;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
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
 * <p>附表行不再按写死的科目名取数(ADR-112)：行目录在 {@link GlReportLine}，行绑定哪些科目/部门存于
 * {@code finance_report_line_bindings}；人工行取已审核工资单应发、折旧行取固定资产折旧事实；
 * 没有绑定的行在「取数口径」列标注「未配置科目/未配置部门」，金额留空且不计入合计。
 * 附 14 按业务员拆分：费用单据无业务员维度，按绑定到「销售费用」的科目出行。</p>
 */
@Service
@RequiredArgsConstructor
public class GlReportService {

    private final EntityManager em;
    private final GlReportLineSource lines;

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

    /** 利润表行集(12 个月)。税金/销售费用/财务费用取各自绑定的科目, 管理费用 = 043 其余科目。 */
    private List<Map<String, Object>> profitRows(int year) {
        LocalDate from = LocalDate.of(year, 1, 1);
        LocalDate to = LocalDate.of(year, 12, 31);
        BigDecimal[] income = monthlyByPaths(year, "INCOME", new String[]{"/031/", "/032/"});
        BigDecimal[] cost = monthlyByPaths(year, "EXPENSE", new String[]{"/041/", "/042/"});
        BigDecimal[] nonOp = monthlyByPaths(year, "INCOME", new String[]{"/033/"});
        List<String> boundKeys = List.of(GlReportLine.PL_TAX.key(), GlReportLine.SALES_FEE.key(),
                GlReportLine.PL_FINANCE.key());
        GlReportLineSource.Bindings bindings = lines.bindings(boundKeys);
        Map<String, BigDecimal[]> bound = lines.styleMonthly(boundKeys, "EXPENSE", from, to);
        BigDecimal[] tax = bound.get(GlReportLine.PL_TAX.key());
        BigDecimal[] sales = bound.get(GlReportLine.SALES_FEE.key());
        BigDecimal[] fin = bound.get(GlReportLine.PL_FINANCE.key());
        BigDecimal[] admin = lines.adminMonthly(boundKeys, from, to);

        String[] labels = {"一、营业收入", "减：营业成本", "营业税金及附加", "销售费用", "管理费用", "财务费用",
                "二、营业利润", "加：营业外收入", "减：营业外支出", "三、利润总额", "减：所得税费用", "四、净利润"};
        List<Map<String, Object>> rows = new ArrayList<>();
        for (String label : labels) {
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("item", label);
            for (int mi = 1; mi <= 12; mi++) {
                BigDecimal inc = at(income, mi), cst = at(cost, mi), tx = at(tax, mi), sl = at(sales, mi);
                BigDecimal ad = at(admin, mi), fn = at(fin, mi), no = at(nonOp, mi);
                BigDecimal opProfit = inc.subtract(cst).subtract(tx).subtract(sl).subtract(ad).subtract(fn);
                BigDecimal total = opProfit.add(no);
                // 未配置科目的行显示空(取数口径列标注), 不计入利润; 已配置但当月没有发生额显示 0。
                BigDecimal v = switch (label) {
                    case "一、营业收入" -> inc;
                    case "减：营业成本" -> cst;
                    case "营业税金及附加" -> bindings.bound(GlReportLine.PL_TAX.key()) ? tx : null;
                    case "销售费用" -> bindings.bound(GlReportLine.SALES_FEE.key()) ? sl : null;
                    case "管理费用" -> ad;
                    case "财务费用" -> bindings.bound(GlReportLine.PL_FINANCE.key()) ? fn : null;
                    case "二、营业利润" -> opProfit;
                    case "加：营业外收入" -> no;
                    case "减：营业外支出" -> null;
                    case "三、利润总额" -> total;
                    case "减：所得税费用" -> null;
                    default -> total; // 四、净利润
                };
                row.put("m" + mi, v);
            }
            row.put("basis", switch (label) {
                case "营业税金及附加" -> basis(GlReportLine.PL_TAX, bindings);
                case "销售费用" -> basis(GlReportLine.SALES_FEE, bindings);
                case "财务费用" -> basis(GlReportLine.PL_FINANCE, bindings);
                case "管理费用" -> "043 费用科目, 扣除已归销售费用/税金/财务费用的科目";
                case "减：营业外支出", "减：所得税费用" -> "暂无数据来源";
                default -> "";
            });
            rows.add(row);
        }
        return rows;
    }

    @Transactional(readOnly = true)
    public ReportTableResponse profitAnnual(int year) {
        List<ReportColumn> cols = new ArrayList<>();
        cols.add(ReportColumn.text("item", "项目", 200));
        for (int mi = 1; mi <= 12; mi++) cols.add(ReportColumn.money("m" + mi, String.format("%02d月", mi)));
        cols.add(ReportColumn.text("basis", "取数口径", 220));
        List<Map<String, Object>> rows = profitRows(year);
        return new ReportTableResponse(cols, rows, new LinkedHashMap<>(), 1, rows.size(), rows.size(), 1);
    }

    @Transactional(readOnly = true)
    public ReportTableResponse profitMonthly(int year, int month) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("item", "项目", 200),
                ReportColumn.money("monthAmount", "本月金额"),
                ReportColumn.money("yearAmount", "本年累计金额"),
                ReportColumn.text("basis", "取数口径", 220));
        List<Map<String, Object>> annual = profitRows(year);
        List<Map<String, Object>> rows = new ArrayList<>();
        for (Map<String, Object> a : annual) {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("item", a.get("item"));
            m.put("monthAmount", a.get("m" + month));
            BigDecimal ytd = null;
            for (int mi = 1; mi <= month; mi++) {
                Object v = a.get("m" + mi);
                if (v instanceof BigDecimal b) ytd = (ytd == null) ? b : ytd.add(b);
            }
            m.put("yearAmount", ytd);
            m.put("basis", a.get("basis"));
            rows.add(m);
        }
        return new ReportTableResponse(cols, rows, new LinkedHashMap<>(), 1, rows.size(), rows.size(), 1);
    }

    /** 按根 path（/031/ 等）聚合月净额：INCOME 取贷净（-dir），EXPENSE 取借净（+dir）。 */
    private BigDecimal[] monthlyByPaths(int year, String category, String[] paths) {
        var q = em.createNativeQuery("""
                SELECT EXTRACT(MONTH FROM e.entry_date)::int,
                       SUM(CASE WHEN :cat = 'INCOME' THEN -e.direction * e.amount ELSE e.direction * e.amount END)
                FROM gl_entries e
                JOIN payment_styles ps ON ps.id = e.style_id
                JOIN payment_styles root ON root.level = 0 AND left(ps.path, length(root.path)) = root.path
                WHERE e.is_deleted = false AND ps.category = :cat AND root.path IN (:paths)
                  AND e.entry_date BETWEEN :from AND :to
                GROUP BY 1
                """);
        q.setParameter("cat", category);
        q.setParameter("paths", List.of(paths));
        q.setParameter("from", LocalDate.of(year, 1, 1));
        q.setParameter("to", LocalDate.of(year, 12, 31));
        BigDecimal[] months = new BigDecimal[13];
        for (Object[] r : NativeQueryResults.objectArrayRows(q)) {
            months[((Number) r[0]).intValue()] = (BigDecimal) r[1];
        }
        return months;
    }

    private static BigDecimal at(BigDecimal[] months, int month) {
        return months == null || months[month] == null ? BigDecimal.ZERO : months[month];
    }

    // ======================== ⑤⑥⑦ 附 12/13/14 费用明细（行=项目 × 列=月） ========================

    @Transactional(readOnly = true)
    public ReportTableResponse manufacturingExpense(int year) {
        Map<String, BigDecimal[]> data = lineMonthly(GlReportLine.MANUFACTURING, year);
        data.put("MFG_OUTPUT", finishedInMonthly(year));
        data.put("MFG_SUBCONTRACT", subcontractMonthly(year));
        return pivotTable("制造费用项目", GlReportLine.MANUFACTURING, data,
                lines.bindings(keys(GlReportLine.MANUFACTURING)));
    }

    @Transactional(readOnly = true)
    public ReportTableResponse adminExpense(int year) {
        Map<String, BigDecimal[]> data = lineMonthly(GlReportLine.ADMIN, year);
        data.put("ADM_SALES", monthlyByPaths(year, "INCOME", new String[]{"/031/"}));
        return pivotTable("管理费用项目", GlReportLine.ADMIN, data, lines.bindings(keys(GlReportLine.ADMIN)));
    }

    /**
     * 附 14 销售费用明细: 一行一个绑定到「销售费用」的科目(费用单据无业务员维度, 按科目出行);
     * 未绑定任何科目时只出一行并标注未配置科目。
     */
    @Transactional(readOnly = true)
    public ReportTableResponse salesExpense(int year) {
        List<ReportColumn> cols = pivotColumns("销售费用项目");
        List<Map<String, Object>> rows = new ArrayList<>();
        // 按科目主键分组: 科目名不唯一(只有编码唯一), 同名科目各出一行、各算各的, 不能互相覆盖。
        List<Object[]> styleRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT style.id, style.code, style.name,
                       EXTRACT(MONTH FROM entry.entry_date)::int, SUM(entry.direction * entry.amount)
                FROM finance_report_line_bindings binding
                JOIN payment_styles style ON style.id = binding.style_id
                LEFT JOIN gl_entries entry ON entry.style_id = style.id AND entry.is_deleted = FALSE
                     AND entry.entry_date BETWEEN :from AND :to
                WHERE binding.line_key = :line AND binding.binding_kind = 'STYLE'
                GROUP BY style.id, style.code, style.name, style.path, 4
                ORDER BY style.path, style.id, 4
                """).setParameter("line", GlReportLine.SALES_FEE.key())
                .setParameter("from", LocalDate.of(year, 1, 1)).setParameter("to", LocalDate.of(year, 12, 31)));
        Map<UUID, BigDecimal[]> byStyle = new LinkedHashMap<>();
        Map<UUID, String[]> styleNames = new LinkedHashMap<>();
        Map<String, Integer> nameUses = new java.util.HashMap<>();
        for (Object[] r : styleRows) {
            UUID styleId = (UUID) r[0];
            if (styleNames.putIfAbsent(styleId, new String[]{(String) r[1], (String) r[2]}) == null) {
                nameUses.merge((String) r[2], 1, Integer::sum);
            }
            // 已配置但当月没有发生额记 0(与「未配置」的空区分开)。
            BigDecimal[] months = byStyle.computeIfAbsent(styleId, ignored -> zeroMonths());
            if (r[3] != null) {
                int month = ((Number) r[3]).intValue();
                months[month] = months[month].add((BigDecimal) r[4]);
            }
        }
        if (byStyle.isEmpty()) {
            rows.add(pivotRow(GlReportLine.SALES_FEE.label(), null, NOT_CONFIGURED_STYLE));
        } else {
            byStyle.forEach((styleId, months) -> {
                String[] codeAndName = styleNames.get(styleId);
                // 同名科目在行标题上带编码区分。
                String label = nameUses.get(codeAndName[1]) > 1
                        ? codeAndName[1] + " (" + codeAndName[0] + ")" : codeAndName[1];
                rows.add(pivotRow(label, months, "科目: " + codeAndName[0] + " " + codeAndName[1]));
            });
        }
        return new ReportTableResponse(cols, rows, new LinkedHashMap<>(), 1, rows.size(), rows.size(), 1);
    }

    private static BigDecimal[] zeroMonths() {
        BigDecimal[] months = new BigDecimal[13];
        java.util.Arrays.fill(months, 1, 13, BigDecimal.ZERO);
        return months;
    }

    /** 一张表里全部可配置行一次取数: 科目行一条语句, 工资行一条, 折旧行一条。 */
    private Map<String, BigDecimal[]> lineMonthly(List<GlReportLine> sheet, int year) {
        Map<String, BigDecimal[]> data = new LinkedHashMap<>();
        data.putAll(lines.styleMonthly(keys(sheet, GlReportLine.Source.STYLES), "EXPENSE",
                LocalDate.of(year, 1, 1), LocalDate.of(year, 12, 31)));
        data.putAll(lines.payrollMonthly(keys(sheet, GlReportLine.Source.PAYROLL), year, null));
        data.putAll(lines.depreciationMonthly(keys(sheet, GlReportLine.Source.DEPRECIATION),
                String.format("%04d-01", year), String.format("%04d-12", year)));
        return data;
    }

    private static List<String> keys(List<GlReportLine> sheet) {
        return sheet.stream().filter(GlReportLine::configurable).map(GlReportLine::key).distinct().toList();
    }

    private static List<String> keys(java.util.Collection<GlReportLine> sheet, GlReportLine.Source source) {
        return sheet.stream().filter(line -> line.source() == source).map(GlReportLine::key).distinct().toList();
    }

    private static List<ReportColumn> pivotColumns(String itemLabel) {
        List<ReportColumn> cols = new ArrayList<>();
        cols.add(ReportColumn.text("item", itemLabel, 180));
        for (int mi = 1; mi <= 12; mi++) cols.add(ReportColumn.money("m" + mi, String.format("%02d月", mi)));
        cols.add(ReportColumn.text("basis", "取数口径", 220));
        return cols;
    }

    /** 通用透视表：行=报表行，列=01..12 月 + 取数口径；未配置的行金额为空并标注。 */
    private static ReportTableResponse pivotTable(String itemLabel, List<GlReportLine> sheet,
                                                  Map<String, BigDecimal[]> data,
                                                  GlReportLineSource.Bindings bindings) {
        List<Map<String, Object>> rows = new ArrayList<>();
        for (GlReportLine line : sheet) {
            boolean unconfigured = line.configurable() && !bindings.bound(line.key());
            rows.add(pivotRow(line.label(), unconfigured ? null : zeroFilled(data.get(line.key())),
                    basis(line, bindings)));
        }
        return new ReportTableResponse(pivotColumns(itemLabel), rows, new LinkedHashMap<>(), 1, rows.size(), rows.size(), 1);
    }

    /** 已配置行(及业务事实行)没有发生额的月份记 0; 只有未配置的行整行留空。 */
    private static BigDecimal[] zeroFilled(BigDecimal[] months) {
        BigDecimal[] filled = zeroMonths();
        if (months != null) {
            for (int mi = 1; mi <= 12; mi++) if (months[mi] != null) filled[mi] = months[mi];
        }
        return filled;
    }

    private static Map<String, Object> pivotRow(String label, BigDecimal[] months, String basis) {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("item", label);
        for (int mi = 1; mi <= 12; mi++) row.put("m" + mi, months == null ? null : months[mi]);
        row.put("basis", basis);
        return row;
    }

    static final String NOT_CONFIGURED_STYLE = "未配置科目";
    static final String NOT_CONFIGURED_DEPARTMENT = "未配置部门";

    /** 行的取数口径说明: 已配置写明来源, 未配置明确标注, 不显示空白。 */
    static String basis(GlReportLine line, GlReportLineSource.Bindings bindings) {
        return switch (line.source()) {
            case FINISHED_IN -> "成品入库金额";
            case SUBCONTRACT -> "委外进仓金额";
            case SALES_INCOME -> "主营业务收入(031)";
            case STYLES -> bindings.bound(line.key())
                    ? "科目: " + String.join("、", bindings.names(line.key())) : NOT_CONFIGURED_STYLE;
            case DEPRECIATION -> bindings.bound(line.key())
                    ? "固定资产折旧: " + String.join("、", bindings.names(line.key())) : NOT_CONFIGURED_STYLE;
            case PAYROLL -> bindings.bound(line.key())
                    ? "已审核工资单应发: " + String.join("、", bindings.names(line.key())) : NOT_CONFIGURED_DEPARTMENT;
        };
    }

    /** 生产产值：成品入库流水月金额（movement_type=13, amount_local）。 */
    private BigDecimal[] finishedInMonthly(int year) {
        var q = em.createNativeQuery("""
                SELECT EXTRACT(MONTH FROM transaction_date)::int, SUM(amount_local)
                FROM stock_movements
                WHERE movement_type = 13 AND transaction_date >= :from AND transaction_date < :to
                GROUP BY 1
                """);
        q.setParameter("from", LocalDate.of(year, 1, 1).atStartOfDay(java.time.ZoneOffset.UTC).toOffsetDateTime());
        q.setParameter("to", LocalDate.of(year + 1, 1, 1).atStartOfDay(java.time.ZoneOffset.UTC).toOffsetDateTime());
        return monthArray(NativeQueryResults.objectArrayRows(q));
    }

    /** 委外加工费：委外进仓行月金额（单头 total_local 老库全 0，取行 amount_local 合计）。 */
    private BigDecimal[] subcontractMonthly(int year) {
        var q = em.createNativeQuery("""
                SELECT EXTRACT(MONTH FROM d.bill_date)::int, SUM(i.amount_local)
                FROM subcontract_receipt_items i
                JOIN subcontract_receipts d ON d.id = i.receipt_id
                WHERE d.status = 1 AND d.is_deleted = false AND i.is_deleted = false
                  AND d.bill_date BETWEEN :from AND :to
                GROUP BY 1
                """);
        q.setParameter("from", LocalDate.of(year, 1, 1));
        q.setParameter("to", LocalDate.of(year, 12, 31));
        return monthArray(NativeQueryResults.objectArrayRows(q));
    }

    private static BigDecimal[] monthArray(List<Object[]> rows) {
        BigDecimal[] months = new BigDecimal[13];
        for (Object[] r : rows) months[((Number) r[0]).intValue()] = (BigDecimal) r[1];
        return months;
    }

    // ======================== ⑧ 附 16 经营损益表 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse operatingPl(int year, int month) {
        LocalDate from = LocalDate.of(year, month, 1);
        LocalDate to = from.plusMonths(1).minusDays(1);
        String period = String.format("%04d-%02d", year, month);
        // 销售额基数 = 031+032 贷净（模板「应收账款」行）
        var baseQ = em.createNativeQuery("""
                SELECT COALESCE(SUM(-e.direction * e.amount),0)
                FROM gl_entries e JOIN payment_styles ps ON ps.id = e.style_id
                JOIN payment_styles root ON root.level = 0 AND left(ps.path, length(root.path)) = root.path
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
                ReportColumn.number("salesRatio", "占销售比%"),
                ReportColumn.text("basis", "取数口径", 220));

        List<Map<String, Object>> rows = new ArrayList<>();
        addOpRow(rows, "应收账款", "", "", base, base, "主营与其他业务收入(031+032)");

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
            addOpRow(rows, "材料费", "主材", (String) r[0], amt, base, "领料数量 × 货品成本");
        }
        addOpRow(rows, "材料费", "材料费合计", "", matTotal, base, "");

        // 一张表的全部可配置行一次取数(科目/工资/折旧各一条语句)。
        List<GlReportLine> opLines = new ArrayList<>(List.of(
                GlReportLine.OP_LABOR_DIRECT, GlReportLine.OP_LABOR_INDIRECT, GlReportLine.OP_MEAL));
        opLines.addAll(GlReportLine.OPERATING_ADMIN.keySet());
        GlReportLineSource.Bindings bindings = lines.bindings(keys(opLines));
        Map<String, BigDecimal[]> data = new LinkedHashMap<>();
        data.putAll(lines.styleMonthly(keys(opLines, GlReportLine.Source.STYLES), "EXPENSE", from, to));
        data.putAll(lines.payrollMonthly(keys(opLines, GlReportLine.Source.PAYROLL), year, month));
        data.putAll(lines.depreciationMonthly(keys(opLines, GlReportLine.Source.DEPRECIATION), period, period));

        // 工费：直接/间接人员工资取已审核工资单, 福利餐费取绑定科目, 委外加工费取进仓事实。
        BigDecimal sub = subcontractMonth(year, month);
        BigDecimal laborTotal = nz(sub);
        for (GlReportLine line : List.of(GlReportLine.OP_LABOR_DIRECT, GlReportLine.OP_LABOR_INDIRECT,
                GlReportLine.OP_MEAL)) {
            BigDecimal amount = lineAmount(line, bindings, data, month);
            laborTotal = laborTotal.add(nz(amount));
            addOpRow(rows, "工费", "劳务费", line.label(), amount, base, basis(line, bindings));
        }
        addOpRow(rows, "工费", "劳务费", "委外加工费", sub, base, "委外进仓金额");
        addOpRow(rows, "工费", "工费合计", "", laborTotal, base, "");

        // 一般管理费(模板行序; 未配置的行明确标注, 不计入合计)
        BigDecimal adminTotal = BigDecimal.ZERO;
        for (var e : GlReportLine.OPERATING_ADMIN.entrySet()) {
            BigDecimal amount = lineAmount(e.getKey(), bindings, data, month);
            adminTotal = adminTotal.add(nz(amount));
            addOpRow(rows, "一般管理费", e.getValue(), e.getKey().label(), amount, base, basis(e.getKey(), bindings));
        }
        addOpRow(rows, "一般管理费", "管理费合计", "", adminTotal, base, "");
        return new ReportTableResponse(cols, rows, new LinkedHashMap<>(), 1, rows.size(), rows.size(), 1);
    }

    /** 已配置行: 本月发生额(没有发生额为 0); 未配置行: 空, 由取数口径列标注。 */
    private static BigDecimal lineAmount(GlReportLine line, GlReportLineSource.Bindings bindings,
                                         Map<String, BigDecimal[]> data, int month) {
        if (!bindings.bound(line.key())) return null;
        BigDecimal[] months = data.get(line.key());
        return months == null || months[month] == null ? BigDecimal.ZERO : months[month];
    }

    private BigDecimal subcontractMonth(int year, int month) {
        LocalDate from = LocalDate.of(year, month, 1);
        var q = em.createNativeQuery("""
                SELECT COALESCE(SUM(i.amount_local),0) FROM subcontract_receipt_items i
                JOIN subcontract_receipts d ON d.id = i.receipt_id
                WHERE d.status=1 AND d.is_deleted=false AND i.is_deleted=false
                  AND d.bill_date BETWEEN :from AND :to
                """);
        q.setParameter("from", from);
        q.setParameter("to", from.plusMonths(1).minusDays(1));
        return (BigDecimal) q.getSingleResult();
    }

    private static void addOpRow(List<Map<String, Object>> rows, String cat, String sub, String item,
                                 BigDecimal amount, BigDecimal base, String basis) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("category", cat);
        m.put("sub", sub);
        m.put("item", item);
        m.put("amount", amount);
        m.put("salesRatio", (amount == null || base == null || base.signum() == 0) ? null
                : MoneyPolicy.percentOf(amount, base));
        m.put("basis", basis);
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
