package com.uten.imp.features.finance.gl;

import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.report.ReportReadPlan;
import com.uten.imp.common.report.ReportQueryKit;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.features.finance.report.ReportColumn;
import com.uten.imp.features.finance.report.ReportFacet;
import com.uten.imp.features.finance.report.ReportTableResponse;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Propagation;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.EnumMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.features.finance.gl.GlReportSourceScopes.Root.*;

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
 *   <li>附 16 经营损益表 {@link #operatingPl}：按库存实际 COGS 变动分类列示已知销售成本，另列当期工费和管理费，
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

    /**
     * Uses the export worker's already established PostgreSQL snapshot. Self invocation here is
     * deliberate: normal GET calls still enter each report's REQUIRES_NEW proxy boundary.
     */
    public ReportTableResponse exportInCurrentSnapshot(String report, LocalDate dateTo, int year, int month) {
        return exportSnapshot(report, dateTo, year, month, null);
    }

    public ReportTableResponse exportInCurrentSnapshot(String report, LocalDate dateTo, int year, int month, int maximum) {
        ReportQueryKit.requireExportRowCount(maximum, 0);
        return exportSnapshot(report, dateTo, year, month, maximum);
    }

    private ReportTableResponse exportSnapshot(String report, LocalDate dateTo, int year, int month, Integer maximum) {
        if (com.uten.imp.common.export.ExportPageSink.current() == null
                || !org.springframework.transaction.support.TransactionSynchronizationManager.isActualTransactionActive()
                || !org.springframework.transaction.support.TransactionSynchronizationManager.isCurrentTransactionReadOnly()
                || !Integer.valueOf(java.sql.Connection.TRANSACTION_REPEATABLE_READ).equals(
                        org.springframework.transaction.support.TransactionSynchronizationManager.getCurrentTransactionIsolationLevel())) {
            throw new IllegalStateException("A report export requires its active read-only repeatable-read snapshot");
        }
        var authentication = org.springframework.security.core.context.SecurityContextHolder.getContext().getAuthentication();
        if (authentication == null || !(authentication.getPrincipal() instanceof com.uten.imp.security.AuthUser user)
                || user.isVisitor() || user.isMustChangePassword() || user.getImpersonatedBy() != null
                || !user.getPermissions().contains("finance_report:view")
                || !user.getPermissions().contains("finance_report:export")
                || (!user.isSuperAdmin() && !user.getPermissions().contains("finance:view:all"))) {
            throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.FORBIDDEN);
        }
        return switch (report) {
            case "gl/balance-sheet" -> balanceSheet(dateTo);
            case "gl/profit-annual" -> profitAnnual(year);
            case "gl/profit-monthly" -> profitMonthly(year, month);
            case "gl/manufacturing-expense" -> manufacturingExpense(year);
            case "gl/admin-expense" -> adminExpense(year);
            case "gl/sales-expense" -> salesExpense(year);
            case "gl/operating-pl" -> maximum == null ? operatingPl(year, month)
                    : buildOperatingPl(year, month, 1, 500, maximum);
            default -> throw new com.uten.imp.common.web.ApiException(
                    com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED, "总账报表类型不正确");
        };
    }

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
        int safePage = Math.max(1, page);
        int safeSize = Math.min(500, Math.max(1, size));
        String sql = """
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
                """;
        var q = com.uten.imp.common.report.ReportExportCursor.query(em, sql + " ORDER BY ps.category, ps.code, ps.name, ps.id LIMIT :__limit OFFSET :__offset")
                .setParameter("__limit", safeSize)
                .setParameter("__offset", (long) (safePage - 1) * safeSize);
        q.setParameter("from", from);
        q.setParameter("to", to);
        List<Object[]> rs = com.uten.imp.common.report.ReportExportCursor.rows(em, q);
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
            ReportQueryKit.includeDecimalTexts(m);
            all.add(m);
        }
        long total = ReportReadPlan.UNKNOWN_TOTAL;
        if (ReportReadPlan.current().includeCount()) {
            total = ((Number) em.createNativeQuery("SELECT COUNT(*) FROM (" + sql + ") balances")
                    .setParameter("from", from).setParameter("to", to).getSingleResult()).longValue();
        }
        return new ReportTableResponse(cols, all, Map.of(), safePage, safeSize, total,
                ReportReadPlan.totalPages(total, safeSize));
    }

    // ======================== ② 附 9 资产负债表 ========================

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ, propagation = Propagation.REQUIRES_NEW)
    public ReportTableResponse balanceSheet(LocalDate dateTo) {
        GlReportSourceScopes.assertUnambiguous(em);
        LocalDate yearStart = dateTo.withDayOfYear(1);
        LocalDate yearOpen = yearStart.minusDays(1);
        Map<GlReportSourceScopes.Root, BigDecimal> end = balancesByRoot(dateTo);
        Map<GlReportSourceScopes.Root, BigDecimal> open = balancesByRoot(yearOpen);

        List<ReportColumn> cols = List.of(
                ReportColumn.text("item", "项目", 200),
                ReportColumn.text("side", "类别", 110),
                ReportColumn.number("lineNo", "行次"),
                ReportColumn.money("periodEnd", "期末余额"),
                ReportColumn.money("yearStart", "年初余额"));
        List<Map<String, Object>> rows = new ArrayList<>();
        // 资产
        BigDecimal cash1 = sum(end, CASH, BANK), cash0 = sum(open, CASH, BANK);
        BigDecimal ar1 = sum(end, RECEIVABLES), ar0 = sum(open, RECEIVABLES);
        BigDecimal oar1 = sum(end, OTHER_RECEIVABLES, OTHER_RECEIVABLES_ALTERNATE), oar0 = sum(open, OTHER_RECEIVABLES, OTHER_RECEIVABLES_ALTERNATE);
        BigDecimal inv1 = sum(end, INVENTORY), inv0 = sum(open, INVENTORY);
        BigDecimal prepaid1 = sum(end, PREPAID), prepaid0 = sum(open, PREPAID);
        BigDecimal fa1 = sum(end, FIXED_ASSETS), fa0 = sum(open, FIXED_ASSETS);
        BigDecimal assets1 = cash1.add(ar1).add(oar1).add(inv1).add(prepaid1).add(fa1);
        BigDecimal assets0 = cash0.add(ar0).add(oar0).add(inv0).add(prepaid0).add(fa0);
        // 负债
        BigDecimal ap1 = sum(end, PAYABLES), ap0 = sum(open, PAYABLES);
        BigDecimal tax1 = sum(end, TAX_PAYABLE), tax0 = sum(open, TAX_PAYABLE);
        BigDecimal oap1 = sum(end, OTHER_PAYABLES, OTHER_PAYABLES_ALTERNATE), oap0 = sum(open, OTHER_PAYABLES, OTHER_PAYABLES_ALTERNATE);
        BigDecimal liab1 = ap1.add(tax1).add(oap1), liab0 = ap0.add(tax0).add(oap0);
        // 权益：期初资本 + 未分配利润（/321/ + 累计损益净额）
        BigDecimal eq1 = sum(end, CAPITAL), eq0 = sum(open, CAPITAL);
        BigDecimal profit1 = sum(end, RETAINED_PROFIT).add(plNet(dateTo));
        BigDecimal profit0 = sum(open, RETAINED_PROFIT).add(plNet(yearOpen));
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

    /** 经来源凭证确认的根分类净额；余额方向沿用根类别，显示编码不参与身份判断。 */
    private Map<GlReportSourceScopes.Root, BigDecimal> balancesByRoot(LocalDate date) {
        var q = em.createNativeQuery(GlReportSourceScopes.balancesSql());
        q.setParameter("d", date);
        Map<GlReportSourceScopes.Root, BigDecimal> result = new EnumMap<>(GlReportSourceScopes.Root.class);
        for (Object[] row : NativeQueryResults.objectArrayRows(q)) {
            result.put(GlReportSourceScopes.Root.valueOf((String) row[0]), (BigDecimal) row[1]);
        }
        return result;
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

    private static BigDecimal sum(Map<GlReportSourceScopes.Root, BigDecimal> m, GlReportSourceScopes.Root... roots) {
        BigDecimal t = BigDecimal.ZERO;
        for (GlReportSourceScopes.Root root : roots) t = t.add(m.getOrDefault(root, BigDecimal.ZERO));
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
        GlReportSourceScopes.assertUnambiguous(em);
        BigDecimal[] income = monthlyByRoots(year, "INCOME", MAIN_REVENUE, OTHER_REVENUE);
        BigDecimal[] cost = monthlyByRoots(year, "EXPENSE", MAIN_COST, OTHER_COST);
        BigDecimal[] nonOp = monthlyByRoots(year, "INCOME", NON_OPERATING_REVENUE);
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

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ, propagation = Propagation.REQUIRES_NEW)
    public ReportTableResponse profitAnnual(int year) {
        List<ReportColumn> cols = new ArrayList<>();
        cols.add(ReportColumn.text("item", "项目", 200));
        for (int mi = 1; mi <= 12; mi++) cols.add(ReportColumn.money("m" + mi, String.format("%02d月", mi)));
        cols.add(ReportColumn.text("basis", "取数口径", 220));
        List<Map<String, Object>> rows = profitRows(year);
        return new ReportTableResponse(cols, rows, new LinkedHashMap<>(), 1, rows.size(), rows.size(), 1);
    }

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ, propagation = Propagation.REQUIRES_NEW)
    public ReportTableResponse profitMonthly(int year, int month) {
        requireMonth(month);
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

    /** 按真实分类树聚合月净额：收入贷净、费用借净，保留原类别与日期口径。 */
    private BigDecimal[] monthlyByRoots(int year, String category, GlReportSourceScopes.Root... roots) {
        var q = em.createNativeQuery(GlReportSourceScopes.monthlySql(roots));
        q.setParameter("cat", category);
        q.setParameter("from", LocalDate.of(year, 1, 1));
        q.setParameter("to", LocalDate.of(year, 12, 31));
        BigDecimal[] months = new BigDecimal[13];
        for (Object[] r : NativeQueryResults.objectArrayRows(q)) {
            months[((Number) r[0]).intValue()] = (BigDecimal) r[1];
        }
        return months;
    }

    private static BigDecimal at(BigDecimal[] months, int month) {
        requireMonth(month);
        if (months == null) return BigDecimal.ZERO;
        if (month >= 0 && month < months.length) {
            BigDecimal amount = months[month];
            return amount == null ? BigDecimal.ZERO : amount;
        }
        throw new IllegalStateException("总账月度取数缺少完整月份");
    }

    private static void requireMonth(int month) {
        if (month < 1 || month > 12) {
            throw new com.uten.imp.common.web.ApiException(
                    com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED, "月份必须在 1 至 12 之间");
        }
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

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ, propagation = Propagation.REQUIRES_NEW)
    public ReportTableResponse adminExpense(int year) {
        GlReportSourceScopes.assertUnambiguous(em);
        Map<String, BigDecimal[]> data = lineMonthly(GlReportLine.ADMIN, year);
        data.put("ADM_SALES", monthlyByRoots(year, "INCOME", MAIN_REVENUE));
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
        LocalDate firstDay = LocalDate.of(year, 1, 1);
        q.setParameter("from", firstDay.atStartOfDay(java.time.ZoneOffset.UTC).toOffsetDateTime());
        q.setParameter("to", firstDay.plusYears(1).atStartOfDay(java.time.ZoneOffset.UTC).toOffsetDateTime());
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

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ, propagation = Propagation.REQUIRES_NEW)
    public ReportTableResponse operatingPl(int year, int month) { return buildOperatingPl(year, month, 1, 50, null); }

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ, propagation = Propagation.REQUIRES_NEW)
    public ReportTableResponse operatingPlPage(int year, int month, int page, int size) {
        return buildOperatingPl(year, month, page, size, null);
    }

    private ReportTableResponse buildOperatingPl(int year, int month, int page, int size, Integer maximum) {
        requireMonth(month);
        GlReportSourceScopes.assertUnambiguous(em);
        LocalDate from = LocalDate.of(year, month, 1);
        LocalDate to = from.plusMonths(1).minusDays(1);
        String period = String.format("%04d-%02d", year, month);
        // 销售额基数 = 031+032 贷净（模板「应收账款」行）
        var baseQ = em.createNativeQuery(GlReportSourceScopes.operatingBaseSql());
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

        var window = new com.uten.imp.common.report.ReportRowWindow(page, size);
        var batches = maximum == null ? null : new com.uten.imp.common.export.ExportRowBatches(
                cols.stream().map(c -> new com.uten.imp.common.export.ExportColumn(
                        c.key(), c.label(), c.type(), null, c.unitLabel(), c.unitKey())).toList(), maximum);
        java.util.function.Consumer<Map<String,Object>> output = batches == null ? window : batches;
        addOpRow(output, "应收账款", "", "", base, base, "主营与其他业务收入(031+032)");

        // COGS is an immutable value delta, including original-cost returns and later source adjustments.
        String materialSql = """
                SELECT COALESCE(mc.name,'未分类'), SUM(m.amount_local),bool_or(m.pending)
                FROM v_stock_actual_cogs_postings m
                LEFT JOIN goods g ON g.id = m.goods_id
                LEFT JOIN material_categories leaf ON leaf.id = g.category_id
                LEFT JOIN material_categories mc ON mc.id = COALESCE(leaf.parent_id, leaf.id)
                WHERE m.business_date BETWEEN :from AND :to
                GROUP BY 1
                ORDER BY 2 DESC,1
                LIMIT :__groupLimit OFFSET :__groupOffset
                """;
        BigDecimal matTotal = BigDecimal.ZERO;
        for (long offset = 0; ; offset += 500) {
            if (Thread.currentThread().isInterrupted()) throw new java.util.concurrent.CancellationException();
            var matQ = com.uten.imp.common.report.ReportExportCursor.query(em, materialSql).setParameter("from", from).setParameter("to", to)
                    .setParameter("__groupLimit", 500).setParameter("__groupOffset", offset);
            List<Object[]> mats = com.uten.imp.common.report.ReportExportCursor.rows(em, matQ);
            for (Object[] r : mats) {
                BigDecimal amt = (BigDecimal) r[1];
                matTotal = matTotal.add(amt);
                addOpRow(output, "已知销售成本", "库存价值", (String) r[0], amt, base,
                        Boolean.TRUE.equals(r[2])?"实际COGS已知部分；仍有待核价来源":"实际COGS变动；含原成本退回及后补差额");
            }
            if (mats.size() < 500) break;
        }
        addOpRow(output, "已知销售成本", "销售成本合计", "", matTotal, base, "本币价值过账；当期费用另列，不等于完整净利润");

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
            addOpRow(output, "工费", "劳务费", line.label(), amount, base, basis(line, bindings));
        }
        addOpRow(output, "工费", "劳务费", "委外加工费", sub, base, "委外进仓金额");
        addOpRow(output, "工费", "工费合计", "", laborTotal, base, "");

        // 一般管理费(模板行序; 未配置的行明确标注, 不计入合计)
        BigDecimal adminTotal = BigDecimal.ZERO;
        for (var e : GlReportLine.OPERATING_ADMIN.entrySet()) {
            BigDecimal amount = lineAmount(e.getKey(), bindings, data, month);
            adminTotal = adminTotal.add(nz(amount));
            addOpRow(output, "一般管理费", e.getValue(), e.getKey().label(), amount, base, basis(e.getKey(), bindings));
        }
        addOpRow(output, "一般管理费", "管理费合计", "", adminTotal, base, "");
        if (batches != null) {
            int total = batches.finish();
            return new ReportTableResponse(cols, List.of(), Map.of(), 1, 500, total, ReportReadPlan.totalPages(total, 500));
        }
        long total = ReportReadPlan.current().includeCount() ? window.count() : ReportReadPlan.UNKNOWN_TOTAL;
        return new ReportTableResponse(cols, window.rows(), Map.of(), window.page(), window.size(), total,
                ReportReadPlan.totalPages(total, window.size()));
    }

    /** 已配置行: 本月发生额(没有发生额为 0); 未配置行: 空, 由取数口径列标注。 */
    private static BigDecimal lineAmount(GlReportLine line, GlReportLineSource.Bindings bindings,
                                         Map<String, BigDecimal[]> data, int month) {
        if (!bindings.bound(line.key())) return null;
        return at(data.get(line.key()), month);
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

    private static void addOpRow(java.util.function.Consumer<Map<String, Object>> rows, String cat, String sub, String item,
                                 BigDecimal amount, BigDecimal base, String basis) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("category", cat);
        m.put("sub", sub);
        m.put("item", item);
        m.put("amount", amount);
        m.put("amountExact",amount==null?null:amount.toPlainString());
        m.put("salesRatio", (amount == null || base == null || base.signum() == 0) ? null
                : MoneyPolicy.percentOf(amount, base));
        if(m.get("salesRatio") instanceof BigDecimal ratio)m.put("salesRatioExact",ratio.toPlainString());
        m.put("basis", basis);
        rows.accept(m);
    }

    private static BigDecimal nz(BigDecimal v) { return v == null ? BigDecimal.ZERO : v; }

    // ======================== 工具 ========================

    private static Object norm(Object v) {
        if (v == null) return null;
        if (v instanceof java.sql.Date d) return d.toLocalDate().toString();
        if (v instanceof java.sql.Timestamp t) return t.toLocalDateTime().toLocalDate().toString();
        if (v instanceof BigDecimal || v instanceof Boolean || v instanceof Number) return v;
        if (v instanceof UUID u) return u.toString();
        return v.toString();
    }
}
