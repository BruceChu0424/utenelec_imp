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
                case "gl/profit-annual"->profitAnnual(year,month);
                case "gl/profit-monthly"->profitMonthly(year,month);
                case "gl/manufacturing-expense"->manufacturingExpense(year,month,options);
                case "gl/admin-expense"->adminExpense(year,month,options);
                case "gl/sales-expense"->salesExpense(year,month,options);
                case "gl/operating-pl"->maximum==null?operatingPl(year,month):buildOperatingPl(year,month,1,500,maximum);
                default->throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,"总账报表类型不正确");
            };
        }
        return switch (report) {
            case "gl/balance-sheet" -> balanceSheet(dateTo,options);
            case "gl/profit-annual" -> profitAnnual(year,month,options);
            case "gl/profit-monthly" -> profitMonthly(year,month,options);
            case "gl/manufacturing-expense" -> manufacturingExpense(year,month,options);
            case "gl/admin-expense" -> adminExpense(year,month,options);
            case "gl/sales-expense" -> salesExpense(year,month,options);
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
        return FinanceTrialBalance.read(em,from,to,page,size,options);
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

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ, propagation = Propagation.REQUIRES_NEW)
    public ReportTableResponse profitAnnual(int year) {
        return profitAnnual(year,12,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);
    }
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ,propagation=Propagation.REQUIRES_NEW)
    public ReportTableResponse profitAnnual(int year,int throughMonth) {
        return profitAnnual(year,throughMonth,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);
    }
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ,propagation=Propagation.REQUIRES_NEW)
    public ReportTableResponse profitAnnual(int year,int throughMonth,com.uten.imp.features.finance.report.FinanceReportColumnOptions options) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        requireMonth(throughMonth);GlReportSourceScopes.assertUnambiguous(em);
        List<ReportColumn> cols = FinancialStatementAnnual.columns(year);
        List<Map<String, Object>> rows = new FinancialStatementService(em).profitAnnual(year,throughMonth);
        FinancialStatementAnnual.totals(rows,throughMonth);
        for(var row:rows)row.put("__basis",row.get("basis"));
        return GlComputedHeaders.apply("gl/profit-annual",new ReportTableResponse(cols, rows, new LinkedHashMap<>(), 1, rows.size(), rows.size(), 1),options);
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
                ReportColumn.text("item", FinanceTemplateContract.header("monthlyProfit",0), 200),
                new ReportColumn("lineNo", FinanceTemplateContract.header("monthlyProfit",1), "int", 70),
                ReportColumn.money("yearAmount", FinanceTemplateContract.header("monthlyProfit",2)).withUnitLabel("元"),
                ReportColumn.money("monthAmount", FinanceTemplateContract.header("monthlyProfit",3)).withUnitLabel("元"),
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
            m.put("__pending",!complete||a.get("m"+month)==null);
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
        return manufacturingExpense(year,12,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);
    }
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public ReportTableResponse manufacturingExpense(int year,int throughMonth,com.uten.imp.features.finance.report.FinanceReportColumnOptions options) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        requireMonth(throughMonth);
        var definitions=new ArrayList<>(GlReportLine.MANUFACTURING);definitions.addAll(GlReportLine.LEGACY_MANUFACTURING);
        Map<String,BigDecimal[]> data=lineMonthly(definitions,year);
        data.put("MFG_OUTPUT",finishedInMonthly(year));
        var bindings=FinanceManufacturingLabor.apply(em,year,data,lines.bindings(keys(definitions)));
        var uncovered=FinanceExpenseReports.zero();for(int month:FinanceManufacturingLabor.uncoveredMonths(em,year)){uncovered[month]=null;}data.put("__MFG_COVERAGE",uncovered);
        applyExpenseLedgerScope(data,definitions,year,throughMonth);
        return FinanceExpenseReports.pivot("manufacturingExpense",year,throughMonth,GlReportLine.MANUFACTURING,GlReportLine.LEGACY_MANUFACTURING,
                data,bindings,FinanceExpenseAnalysisReader.confirmedPolicies(em,year),options);
    }

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public ReportTableResponse manufacturingExpense(int year,com.uten.imp.features.finance.report.FinanceReportColumnOptions options) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        return manufacturingExpense(year,12,options);
    }

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ, propagation = Propagation.REQUIRES_NEW)
    public ReportTableResponse adminExpense(int year) {
        return adminExpense(year,12,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);
    }
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ,propagation=Propagation.REQUIRES_NEW)
    public ReportTableResponse adminExpense(int year,int throughMonth,com.uten.imp.features.finance.report.FinanceReportColumnOptions options) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        requireMonth(throughMonth);
        GlReportSourceScopes.assertUnambiguous(em);
        var definitions=new ArrayList<>(GlReportLine.ADMIN);definitions.addAll(GlReportLine.LEGACY_ADMIN);
        Map<String,BigDecimal[]> data=lineMonthly(definitions,year);
        BigDecimal[] revenue=new BigDecimal[13];
        FinancialStatementRevenue.months(em,access,year,throughMonth).forEach((month,value)->revenue[month]=value.complete()?value.amount():null);
        data.put("ADM_SALES",revenue);
        applyExpenseLedgerScope(data,definitions,year,throughMonth);
        return FinanceExpenseReports.pivot("adminExpense",year,throughMonth,GlReportLine.ADMIN,GlReportLine.LEGACY_ADMIN,
                data,lines.bindings(keys(definitions)),java.util.Set.of(),options);
    }

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ,propagation=Propagation.REQUIRES_NEW)
    public ReportTableResponse adminExpense(int year,com.uten.imp.features.finance.report.FinanceReportColumnOptions options) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        return adminExpense(year,12,options);
    }

    /**
     * 附 14 销售费用明细: 一行一个绑定到「销售费用」的科目(费用单据无业务员维度, 按科目出行);
     * 未绑定任何科目时只出一行并标注未配置科目。
     */
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public ReportTableResponse salesExpense(int year) {
        return salesExpense(year,12,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);
    }
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public ReportTableResponse salesExpense(int year,int throughMonth,com.uten.imp.features.finance.report.FinanceReportColumnOptions options) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        requireMonth(throughMonth);
        var report=FinanceSalesExpenseReport.read(em,lines,year,throughMonth,FinancialStatementRevenue.months(em,access,year,throughMonth));
        return FinanceExpenseReports.filtered(report.columns(),report.rows(),options);
    }

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public ReportTableResponse salesExpense(int year,com.uten.imp.features.finance.report.FinanceReportColumnOptions options) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        return salesExpense(year,12,options);
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
                String.format("%04d-01", year), String.format("%04d-12", year),"FA"));
        data.putAll(lines.depreciationMonthly(keys(sheet, GlReportLine.Source.AMORTIZATION),
                String.format("%04d-01", year), String.format("%04d-12", year),"DA"));
        return data;
    }
    private void applyExpenseLedgerScope(Map<String,BigDecimal[]> data,List<GlReportLine> definitions,int year,int throughMonth){
        var coverage=FinancialLedgerReadScope.months(em,year,throughMonth);
        var proof=FinanceExpenseReports.zero();for(int m=1;m<=throughMonth;m++){if(!coverage.get(m).complete())proof[m]=null;}data.put("__LEDGER_READ_SCOPE",proof);
        for(var definition:definitions)if(definition.source()!=GlReportLine.Source.FINISHED_IN){
            var values=data.computeIfAbsent(definition.key(),k->FinanceExpenseReports.zero());
            for(int m=1;m<=12;m++)if(m>throughMonth||!coverage.get(m).complete())values[m]=null;
        }
    }

    private static List<String> keys(List<GlReportLine> sheet) {
        return sheet.stream().filter(GlReportLine::configurable).map(GlReportLine::key).distinct().toList();
    }

    private static List<String> keys(java.util.Collection<GlReportLine> sheet, GlReportLine.Source source) {
        return sheet.stream().filter(line -> line.source() == source).map(GlReportLine::key).distinct().toList();
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
            case AMORTIZATION -> bindings.bound(line.key()) ? "长期待摊实际摊销: " + String.join("、",bindings.names(line.key())) : NOT_CONFIGURED_STYLE;
            case DEPRECIATION -> bindings.bound(line.key())
                    ? "固定资产折旧: " + String.join("、", bindings.names(line.key())) : NOT_CONFIGURED_STYLE;
            case PAYROLL -> bindings.bound(line.key())
                    ? "已记账工资成本（明确原部门）: " + String.join("、", bindings.names(line.key())) : NOT_CONFIGURED_DEPARTMENT;
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
        requireMonth(month);GlReportSourceScopes.assertUnambiguous(em);
        var candidates=com.uten.imp.features.finance.report.FinanceReportColumnCandidates.current();
        if(candidates!=null)candidates.requireVisibleText(FinanceExpenseReports.operatingColumns(month),java.util.Set.of());
        var definitions=GlReportLine.operatingLines();
        var data=lineMonthly(definitions,year);var bindings=FinanceManufacturingLabor.apply(em,year,data,lines.bindings(keys(definitions)));
        applyExpenseLedgerScope(data,definitions,year,month);
        var response=FinanceExpenseReports.operating(month,data,bindings,
                FinancialStatementRevenue.months(em,access,year,month),FinanceExpenseAnalysisReader.confirmedPolicies(em,year),
                FinanceExpenseAnalysisReader.notes(em,"%04d-%02d".formatted(year,month)),options,
                candidates==null?page:1,candidates==null?size:500,candidates==null?maximum:null);
        if(candidates!=null) {
            if(response.total()<0||response.total()>response.rows().size())
                throw new IllegalStateException("Report candidates require the complete owning projection");
            var condition=GlComputedHeaders.compile(response.columns(),options);
            response.rows().stream().filter(condition::matches).forEach(candidates::addRecord);
            candidates.finishRecords(response.columns());
            return new ReportTableResponse(response.columns(),List.of(),Map.of(),1,1,0,0).withColumnSearchKeys(response.columnSearchKeys());
        }
        return response;
    }
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
