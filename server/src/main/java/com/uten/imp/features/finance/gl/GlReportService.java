package com.uten.imp.features.finance.gl;

import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.report.ReportReadPlan;
import com.uten.imp.common.report.ReportQueryKit;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.features.finance.report.ReportColumn;
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
 *       通过 FinancialStatementCatalog/Service 统一映射与公式，收入贷净、费用借净；
 *       其中行只归集一次，缺少映射时合计明确保留未知。</li>
 *   <li>附 12 制造费用明细 {@link #manufacturingExpense} / 附 13 管理费用明细 {@link #adminExpense} /
 *       附 14 销售费用明细 {@link #salesExpense}：科目月金额透视（行=项目，列=01..12 月）。</li>
 *   <li>附 16 经营损益表 {@link #operatingPl}：按库存实际 COGS 变动分类列示已知销售成本，另列当期工费和管理费，
 *       占销售比=金额/销售额(031+032 贷净)。</li>
 * </ol>
 *
 * <p>附表行不再按写死的科目名取数(ADR-112)：行目录在 {@link GlReportLine}，行绑定哪些科目/部门存于
 * {@code finance_report_line_bindings}；人工行取已审核工资单应发、折旧行取固定资产折旧事实；
 * 没有绑定的行在「取数口径」列标注「未配置科目/未配置部门」，金额留空，依赖该行的合计同样保留未知。
 * 附 14 按业务员拆分：费用单据无业务员维度，按绑定到「销售费用」的科目出行。</p>
 */
@Service
@RequiredArgsConstructor
public class GlReportService {

    private final EntityManager em;
    private final GlReportLineSource lines;
    private final com.uten.imp.features.finance.FinanceDocumentAccessPolicy access;

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

    public ReportTableResponse exportInCurrentSnapshot(String report,LocalDate dateTo,int year,int month,
            com.uten.imp.features.finance.report.FinanceReportColumnOptions options) {
        return exportSnapshot(report,dateTo,year,month,null,options);
    }
    public ReportTableResponse exportInCurrentSnapshot(String report,LocalDate dateTo,int year,int month,int maximum,
            com.uten.imp.features.finance.report.FinanceReportColumnOptions options) {
        ReportQueryKit.requireExportRowCount(maximum,0);return exportSnapshot(report,dateTo,year,month,maximum,options);
    }

    private ReportTableResponse exportSnapshot(String report, LocalDate dateTo, int year, int month, Integer maximum) {
        return exportSnapshot(report,dateTo,year,month,maximum,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);
    }
    private ReportTableResponse exportSnapshot(String report,LocalDate dateTo,int year,int month,Integer maximum,
            com.uten.imp.features.finance.report.FinanceReportColumnOptions options) {
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
        if(options.filters().isEmpty()&&options.sort()==null&&options.order()==null) {
            return switch(report) {
                case "gl/balance-sheet"->balanceSheet(dateTo);
                case "gl/profit-annual"->profitAnnual(year);
                case "gl/profit-monthly"->profitMonthly(year,month);
                case "gl/manufacturing-expense"->manufacturingExpense(year);
                case "gl/admin-expense"->adminExpense(year);
                case "gl/sales-expense"->salesExpense(year);
                case "gl/operating-pl"->maximum==null?operatingPl(year,month):buildOperatingPl(year,month,1,500,maximum);
                default->throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,"总账报表类型不正确");
            };
        }
        return switch (report) {
            case "gl/balance-sheet" -> balanceSheet(dateTo,options);
            case "gl/profit-annual" -> profitAnnual(year,options);
            case "gl/profit-monthly" -> profitMonthly(year,month,options);
            case "gl/manufacturing-expense" -> manufacturingExpense(year,options);
            case "gl/admin-expense" -> adminExpense(year,options);
            case "gl/sales-expense" -> salesExpense(year,options);
            case "gl/operating-pl" -> maximum == null ? buildOperatingPl(year,month,1,50,null,options)
                    : buildOperatingPl(year,month,1,500,maximum,options);
            default -> throw new com.uten.imp.common.web.ApiException(
                    com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED, "总账报表类型不正确");
        };
    }

    // ======================== ① 科目余额表 ========================

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public ReportTableResponse trialBalance(LocalDate from, LocalDate to, int page, int size) {
        return trialBalance(from,to,page,size,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);
    }

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public ReportTableResponse trialBalance(LocalDate from,LocalDate to,int page,int size,
            com.uten.imp.features.finance.report.FinanceReportColumnOptions options) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        List<ReportColumn> cols = List.of(
                ReportColumn.text("styleCode", "科目编码", 90),
                ReportColumn.text("styleName", "科目名称", 180),
                ReportColumn.number("level", "级次"),
                ReportColumn.text("category", "类别", 90),
                ReportColumn.money("opening", "期初余额").withUnitLabel("元"),
                ReportColumn.money("debit", "本期借方").withUnitLabel("元").totaled("所列记录本期借方合计"),
                ReportColumn.money("credit", "本期贷方").withUnitLabel("元").totaled("所列记录本期贷方合计"),
                ReportColumn.money("closing", "期末余额").withUnitLabel("元"));
        var projected=new ArrayList<>(cols);projected.add(ReportColumn.text("__styleId","",1));
        String sql = """
                WITH agg AS (
                    SELECT style_id,
                           SUM(CASE WHEN entry_date < :from THEN direction * amount ELSE 0 END) AS opening_net,
                           SUM(CASE WHEN entry_date BETWEEN :from AND :to AND direction = 1 THEN amount ELSE 0 END) AS debit,
                           SUM(CASE WHEN entry_date BETWEEN :from AND :to AND direction = -1 THEN amount ELSE 0 END) AS credit
                    FROM gl_entries WHERE is_deleted = false
                    GROUP BY style_id
                )
                SELECT ps.code AS "styleCode", ps.name AS "styleName", ps.level, ps.category,
                       CASE WHEN ps.category IN ('ACCOUNT','EXPENSE') THEN a.opening_net ELSE -a.opening_net END AS opening,
                       a.debit, a.credit,
                       CASE WHEN ps.category IN ('ACCOUNT','EXPENSE')
                            THEN a.opening_net + a.debit - a.credit
                            ELSE -(a.opening_net + a.debit - a.credit) END AS closing,ps.id AS "__styleId"
                FROM agg a JOIN payment_styles ps ON ps.id = a.style_id
                """;
        return com.uten.imp.features.finance.report.FinanceProjectedReportTable.query(em,projected,sql,
                q->{q.setParameter("from",from);q.setParameter("to",to);},
                "report.\"category\",report.\"styleCode\",report.\"styleName\",report.\"__styleId\"",
                options.filters(),java.util.Set.of("category"),page,size,options.sort(),options.order(),false,
                com.uten.imp.features.finance.report.FinanceProjectedReportTable.totalSpecs(cols,projected));
    }

    // ======================== ② 附 9 资产负债表 ========================

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ, propagation = Propagation.REQUIRES_NEW)
    public ReportTableResponse balanceSheet(LocalDate dateTo) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        GlReportSourceScopes.assertUnambiguous(em);
        List<ReportColumn> cols = List.of(
                ReportColumn.text("item", "项目", 260), ReportColumn.text("side", "类别", 110),
                new ReportColumn("lineNo", "行次", "int", 70),
                ReportColumn.money("periodEnd", "期末余额").withUnitLabel("元"),
                ReportColumn.money("yearStart", "年初余额").withUnitLabel("元"),
                ReportColumn.text("basis", "取数口径", 280));
        List<Map<String,Object>> rows = new FinancialStatementService(em).balance(dateTo);
        return GlComputedHeaders.apply("gl/balance-sheet",new ReportTableResponse(cols, rows, new LinkedHashMap<>(), 1, rows.size(), rows.size(), 1),com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);
    }

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ,propagation=Propagation.REQUIRES_NEW)
    public ReportTableResponse balanceSheet(LocalDate dateTo,com.uten.imp.features.finance.report.FinanceReportColumnOptions options) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        return GlComputedHeaders.apply("gl/balance-sheet",balanceSheet(dateTo),options);
    }

    /** Monthly and annual statements share the same template, account allocation and formulas. */
    private List<Map<String, Object>> profitRows(int year) {
        GlReportSourceScopes.assertUnambiguous(em);
        return new FinancialStatementService(em).profit(year);
    }

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ, propagation = Propagation.REQUIRES_NEW)
    public ReportTableResponse profitAnnual(int year) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        List<ReportColumn> cols = new ArrayList<>();
        cols.add(ReportColumn.text("item", "项目", 260));
        cols.add(new ReportColumn("lineNo", "行次", "int", 70));
        for (int mi = 1; mi <= 12; mi++) cols.add(ReportColumn.money("m" + mi, String.format("%02d月", mi)));
        cols.add(ReportColumn.text("basis", "取数口径", 220));
        List<Map<String, Object>> rows = profitRows(year);
        return GlComputedHeaders.apply("gl/profit-annual",new ReportTableResponse(cols, rows, new LinkedHashMap<>(), 1, rows.size(), rows.size(), 1),com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);
    }

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ,propagation=Propagation.REQUIRES_NEW)
    public ReportTableResponse profitAnnual(int year,com.uten.imp.features.finance.report.FinanceReportColumnOptions options) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        return GlComputedHeaders.apply("gl/profit-annual",profitAnnual(year),options);
    }

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ, propagation = Propagation.REQUIRES_NEW)
    public ReportTableResponse profitMonthly(int year, int month) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        requireMonth(month);
        List<ReportColumn> cols = List.of(
                ReportColumn.text("item", "项目", 200),
                new ReportColumn("lineNo", "行次", "int", 70),
                ReportColumn.money("yearAmount", "本年累计金额").withUnitLabel("元"),
                ReportColumn.money("monthAmount", "本月金额").withUnitLabel("元"),
                ReportColumn.text("basis", "取数口径", 220));
        GlReportSourceScopes.assertUnambiguous(em);
        List<Map<String, Object>> annual = new FinancialStatementService(em).profit(year,month);
        List<Map<String, Object>> rows = new ArrayList<>();
        for (Map<String, Object> a : annual) {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("item", a.get("item"));
            m.put("lineNo", a.get("lineNo"));
            m.put("monthAmount", a.get("m" + month));
            BigDecimal ytd = BigDecimal.ZERO;
            boolean complete = true;
            for (int mi = 1; mi <= month; mi++) {
                Object v = a.get("m" + mi);
                if (v instanceof BigDecimal b) ytd = ytd.add(b); else complete = false;
            }
            m.put("yearAmount", complete ? ytd : null);
            m.put("basis", a.get("basis"));
            rows.add(m);
        }
        return GlComputedHeaders.apply("gl/profit-monthly",new ReportTableResponse(cols, rows, new LinkedHashMap<>(), 1, rows.size(), rows.size(), 1),com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);
    }

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ,propagation=Propagation.REQUIRES_NEW)
    public ReportTableResponse profitMonthly(int year,int month,com.uten.imp.features.finance.report.FinanceReportColumnOptions options) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        return GlComputedHeaders.apply("gl/profit-monthly",profitMonthly(year,month),options);
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

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public ReportTableResponse manufacturingExpense(int year) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        Map<String, BigDecimal[]> data = lineMonthly(GlReportLine.MANUFACTURING, year);
        data.put("MFG_OUTPUT", finishedInMonthly(year));
        data.put("MFG_SUBCONTRACT", subcontractMonthly(year));
        return pivotTable("制造费用项目", GlReportLine.MANUFACTURING, data,
                lines.bindings(keys(GlReportLine.MANUFACTURING)));
    }

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public ReportTableResponse manufacturingExpense(int year,com.uten.imp.features.finance.report.FinanceReportColumnOptions options) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        return GlComputedHeaders.apply("gl/manufacturing-expense",manufacturingExpense(year),options);
    }

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ, propagation = Propagation.REQUIRES_NEW)
    public ReportTableResponse adminExpense(int year) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        GlReportSourceScopes.assertUnambiguous(em);
        Map<String, BigDecimal[]> data = lineMonthly(GlReportLine.ADMIN, year);
        data.put("ADM_SALES", monthlyByRoots(year, "INCOME", MAIN_REVENUE));
        return pivotTable("管理费用项目", GlReportLine.ADMIN, data, lines.bindings(keys(GlReportLine.ADMIN)));
    }

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ,propagation=Propagation.REQUIRES_NEW)
    public ReportTableResponse adminExpense(int year,com.uten.imp.features.finance.report.FinanceReportColumnOptions options) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        return GlComputedHeaders.apply("gl/admin-expense",adminExpense(year),options);
    }

    /**
     * 附 14 销售费用明细: 一行一个绑定到「销售费用」的科目(费用单据无业务员维度, 按科目出行);
     * 未绑定任何科目时只出一行并标注未配置科目。
     */
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public ReportTableResponse salesExpense(int year) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
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
        return GlComputedHeaders.apply("gl/sales-expense",new ReportTableResponse(cols, rows, new LinkedHashMap<>(), 1, rows.size(), rows.size(), 1),com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);
    }

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public ReportTableResponse salesExpense(int year,com.uten.imp.features.finance.report.FinanceReportColumnOptions options) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        return GlComputedHeaders.apply("gl/sales-expense",salesExpense(year),options);
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
            boolean businessFact = line.source() == GlReportLine.Source.FINISHED_IN
                    || line.source() == GlReportLine.Source.SUBCONTRACT;
            BigDecimal[] months = unconfigured ? null : businessFact ? data.get(line.key())
                    : zeroFilled(data.get(line.key()));
            String sourceBasis = basis(line, bindings);
            if (businessFact && months != null
                    && java.util.stream.IntStream.rangeClosed(1, 12).anyMatch(month -> months[month] == null)) {
                sourceBasis += "（空值月份存在待核实金额）";
            }
            rows.add(pivotRow(line.label(), months, sourceBasis));
        }
        return GlComputedHeaders.apply("gl/pivot",new ReportTableResponse(pivotColumns(itemLabel), rows, new LinkedHashMap<>(), 1, rows.size(), rows.size(), 1),com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);
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

    /** 生产产值：业务月内成品入库净额，红冲按方向抵销；缺失成本不冒充零。 */
    private BigDecimal[] finishedInMonthly(int year) {
        var q = em.createNativeQuery("""
                SELECT EXTRACT(MONTH FROM transaction_date AT TIME ZONE 'Asia/Shanghai')::int,
                       CASE WHEN bool_or(amount_local IS NULL) THEN NULL
                            ELSE SUM(direction * amount_local) END
                FROM stock_movements
                WHERE movement_type = 13 AND transaction_date >= :from AND transaction_date < :to
                GROUP BY 1
                """);
        LocalDate firstDay = LocalDate.of(year, 1, 1);
        q.setParameter("from", com.uten.imp.common.time.BusinessTime.startOfDay(firstDay));
        q.setParameter("to", com.uten.imp.common.time.BusinessTime.startOfDay(firstDay.plusYears(1)));
        return monthArray(NativeQueryResults.objectArrayRows(q));
    }

    /** 委外加工费：委外进仓行月金额（单头 total_local 老库全 0，取行 amount_local 合计）。 */
    private BigDecimal[] subcontractMonthly(int year) {
        var q = em.createNativeQuery("""
                SELECT EXTRACT(MONTH FROM d.bill_date)::int,
                       CASE WHEN bool_or(i.amount_local IS NULL) THEN NULL ELSE SUM(i.amount_local) END
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
        BigDecimal[] months = zeroMonths();
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

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ,propagation=Propagation.REQUIRES_NEW)
    public ReportTableResponse operatingPlPage(int year,int month,int page,int size,
            com.uten.imp.features.finance.report.FinanceReportColumnOptions options) {
        return buildOperatingPl(year,month,page,size,null,options);
    }

    private ReportTableResponse buildOperatingPl(int year, int month, int page, int size, Integer maximum) {
        return buildOperatingPl(year,month,page,size,maximum,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);
    }
    private ReportTableResponse buildOperatingPl(int year,int month,int page,int size,Integer maximum,
            com.uten.imp.features.finance.report.FinanceReportColumnOptions options) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
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
        var condition=GlComputedHeaders.compile(cols,options);
        var candidates=com.uten.imp.features.finance.report.FinanceReportColumnCandidates.current();
        if(candidates!=null)candidates.requireVisibleText(cols,java.util.Set.of());
        java.util.function.Consumer<Map<String,Object>> destination = batches == null ? window : batches;
        var matchedCategories=new java.util.HashSet<String>();
        java.util.function.Consumer<Map<String,Object>> output = row -> {
            String category=(String)row.get("category");
            boolean matched=condition.matches(row);
            if(candidates!=null&&matched)candidates.addRecord(row);
            boolean subtotal=Boolean.TRUE.equals(row.remove("__glSubtotal"));
            if(matched || (subtotal && matchedCategories.contains(category)))destination.accept(row);
            if(matched && !subtotal)matchedCategories.add(category);
        };
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
        addOpRow(output, "已知销售成本", "销售成本合计", "", matTotal, base, "本币价值过账；当期费用另列，不等于完整净利润",true);

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
        boolean laborComplete = sub != null;
        for (GlReportLine line : List.of(GlReportLine.OP_LABOR_DIRECT, GlReportLine.OP_LABOR_INDIRECT,
                GlReportLine.OP_MEAL)) {
            BigDecimal amount = lineAmount(line, bindings, data, month);
            laborTotal = laborTotal.add(nz(amount));
            laborComplete &= amount != null;
            addOpRow(output, "工费", "劳务费", line.label(), amount, base, basis(line, bindings));
        }
        addOpRow(output, "工费", "劳务费", "委外加工费", sub, base, "委外进仓金额");
        addOpRow(output, "工费", "工费合计", "", laborComplete ? laborTotal : null, base,
                laborComplete ? "" : "组成项目尚未配置完整或来源金额待核实",true);

        // 一般管理费(模板行序; 未配置的行明确标注, 不输出不完整合计)
        BigDecimal adminTotal = BigDecimal.ZERO;
        boolean adminComplete = true;
        for (var e : GlReportLine.OPERATING_ADMIN.entrySet()) {
            BigDecimal amount = lineAmount(e.getKey(), bindings, data, month);
            adminTotal = adminTotal.add(nz(amount));
            adminComplete &= amount != null;
            addOpRow(output, "一般管理费", e.getValue(), e.getKey().label(), amount, base, basis(e.getKey(), bindings));
        }
        addOpRow(output, "一般管理费", "管理费合计", "", adminComplete ? adminTotal : null, base,
                adminComplete ? "" : "组成项目尚未配置完整或来源金额待核实",true);
        if(candidates!=null) {
            candidates.finishRecords(cols);
            return new ReportTableResponse(cols,List.of(),Map.of(),1,1,0,0).withColumnSearchKeys(condition.keys());
        }
        if (batches != null) {
            int total = batches.finish();
            return new ReportTableResponse(cols, List.of(), Map.of(), 1, 500, total, ReportReadPlan.totalPages(total, 500)).withColumnSearchKeys(condition.keys());
        }
        long total = ReportReadPlan.current().includeCount() ? window.count() : ReportReadPlan.UNKNOWN_TOTAL;
        return new ReportTableResponse(cols, window.rows(), Map.of(), window.page(), window.size(), total,
                ReportReadPlan.totalPages(total, window.size())).withColumnSearchKeys(condition.keys());
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
                SELECT CASE WHEN bool_or(i.amount_local IS NULL) THEN NULL ELSE COALESCE(SUM(i.amount_local),0) END
                FROM subcontract_receipt_items i
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
        addOpRow(rows,cat,sub,item,amount,base,basis,false);
    }
    private static void addOpRow(java.util.function.Consumer<Map<String,Object>> rows,String cat,String sub,String item,
                                 BigDecimal amount,BigDecimal base,String basis,boolean subtotal) {
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
        if(subtotal)m.put("__glSubtotal",true);
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
