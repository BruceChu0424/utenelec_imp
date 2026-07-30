package com.uten.imp.features.finance.cost;

import com.uten.imp.features.finance.report.ReportTableResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;

import static org.springframework.format.annotation.DateTimeFormat.ISO;

/**
 * 成本核算报表 API（C4 · 王少春 4 项）。
 *
 * <ul>
 *   <li>GET /api/finance/reports/cost/product —— 产品成本汇总（标准 13 项 + 期间实际对比）。</li>
 *   <li>GET /api/finance/reports/cost/sales-summary —— 附件 15 销售成本核算汇总（按客户）。</li>
 *   <li>GET /api/finance/reports/cost/copper-fee —— 附件 7 铜柱加工费核算（keyword 按加工商）。</li>
 *   <li>GET /api/finance/reports/cost/copper-pickling —— 附件 7-1 插套酸洗入库明细。</li>
 *   <li>GET /api/finance/reports/cost/plastic —— 附件 8 塑料耗用明细（车间口径）。</li>
 *   <li>GET /api/finance/reports/cost/plastic-detail?kind=issue|return|finished —— 附件 8-1/8-2/8-3。</li>
 * </ul>
 *
 * <p>通用参数：keyword / dateFrom / dateTo / page / size。权限 {@code finance_report:view}。</p>
 */
@RestController
@RequestMapping("/api/finance/reports/cost")
@RequiredArgsConstructor
public class FinanceCostController {

    private final FinanceCostService service;

    @GetMapping("/product")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse product(
            @RequestParam(required = false) String keyword,
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.productCost(keyword, dateFrom, dateTo, page, size);
    }

    @GetMapping("/sales-summary")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse salesSummary(
            @RequestParam(required = false) String keyword,
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.salesCostSummary(keyword, dateFrom, dateTo, page, size);
    }

    @GetMapping("/copper-fee")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse copperFee(
            @RequestParam(required = false) String keyword,
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.copperFee(keyword, dateFrom, dateTo, page, size);
    }

    @GetMapping("/copper-pickling")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse copperPickling(
            @RequestParam(required = false) String keyword,
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.copperPickling(keyword, dateFrom, dateTo, page, size);
    }

    @GetMapping("/plastic")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse plastic(
            @RequestParam(required = false) String keyword,
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.plasticUsage(keyword, dateFrom, dateTo, page, size);
    }

    @GetMapping("/plastic-detail")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse plasticDetail(
            @RequestParam(required = false) String kind,
            @RequestParam(required = false) String keyword,
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.plasticDetail(kind, keyword, dateFrom, dateTo, page, size);
    }
}
