package com.uten.imp.features.finance.gl;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.finance.report.ReportTableResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.Map;

import static org.springframework.format.annotation.DateTimeFormat.ISO;

/**
 * 总账子系统 API（C3）。
 *
 * <p>过账（写）：POST /api/finance/gl/generate?period=YYYY-MM（幂等重生成该期间 AUTO 凭证）；
 * POST /api/finance/gl/generate-all（重放全部历史期间，耗时较长）。</p>
 *
 * <p>报表（读，/api/finance/reports/gl/*，权限 finance_report:view）：
 * trial-balance 科目余额表 / balance-sheet 附 9 / profit-annual 附 10 / profit-monthly 附 11 /
 * manufacturing-expense 附 12 / admin-expense 附 13 / sales-expense 附 14 / operating-pl 附 16。</p>
 */
@RestController
@RequiredArgsConstructor
public class GlController {

    private final GlPostingService posting;
    private final GlReportService reports;

    // ======================== 过账 ========================

    @PostMapping("/api/finance/gl/generate")
    @PreAuthorize("hasAuthority('finance_post:execute')")
    public Map<String, Object> generate(@RequestParam String period) {
        if (!period.matches("\\d{4}-\\d{2}")) {
            throw new IllegalArgumentException("period 格式 YYYY-MM");
        }
        int vouchers = posting.generate(period);
        return Map.of("period", period, "vouchers", vouchers);
    }

    @PostMapping("/api/finance/gl/generate-all")
    @PreAuthorize("hasAuthority('finance_post:execute')")
    public Map<String, Object> generateAll() {
        int periods = posting.generateAll();
        return Map.of("periods", periods);
    }

    // ======================== 报表 ========================

    /** 科目余额表。 */
    @GetMapping("/api/finance/reports/gl/trial-balance")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse trialBalance(
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return reports.trialBalance(dateFrom, dateTo, page, size);
    }

    /** 附 9 资产负债表（dateTo=报表日；年初列=该年 1 月 1 日前）。 */
    @GetMapping("/api/finance/reports/gl/balance-sheet")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse balanceSheet(
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo) {
        return reports.balanceSheet(dateTo);
    }

    /** 附 10 年度利润汇总（行=项目 × 列=12 月）。year 缺省取 dateTo 年（通用报表页只传日期）。 */
    @GetMapping("/api/finance/reports/gl/profit-annual")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse profitAnnual(
            @RequestParam(required = false) Integer year,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo) {
        return reports.profitAnnual(yearOf(year, dateTo));
    }

    /** 附 11 月度利润表（本月+本年累计）。year/month 缺省取 dateTo 年/月。 */
    @GetMapping("/api/finance/reports/gl/profit-monthly")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse profitMonthly(
            @RequestParam(required = false) Integer year,
            @RequestParam(required = false) Integer month,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo) {
        return reports.profitMonthly(yearOf(year, dateTo), monthOf(month, dateTo));
    }

    /** 附 12 制造费用明细。 */
    @GetMapping("/api/finance/reports/gl/manufacturing-expense")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse manufacturingExpense(
            @RequestParam(required = false) Integer year,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo) {
        return reports.manufacturingExpense(yearOf(year, dateTo));
    }

    /** 附 13 管理费用明细。 */
    @GetMapping("/api/finance/reports/gl/admin-expense")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse adminExpense(
            @RequestParam(required = false) Integer year,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo) {
        return reports.adminExpense(yearOf(year, dateTo));
    }

    /** 附 14 销售费用明细（按费用科目；费用单据无业务员维度，按人拆分不可推导）。 */
    @GetMapping("/api/finance/reports/gl/sales-expense")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse salesExpense(
            @RequestParam(required = false) Integer year,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo) {
        return reports.salesExpense(yearOf(year, dateTo));
    }

    /** 附 16 经营损益表（占销售比口径）。 */
    @GetMapping("/api/finance/reports/gl/operating-pl")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse operatingPl(
            @RequestParam(required = false) Integer year,
            @RequestParam(required = false) Integer month,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo) {
        return reports.operatingPl(yearOf(year, dateTo), monthOf(month, dateTo));
    }

    private static int yearOf(Integer year, LocalDate dateTo) {
        if (year != null) return year;
        return (dateTo != null ? dateTo : BusinessTime.today()).getYear();
    }

    private static int monthOf(Integer month, LocalDate dateTo) {
        if (month != null) return month;
        return (dateTo != null ? dateTo : BusinessTime.today()).getMonthValue();
    }
}
