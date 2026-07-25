package com.uten.imp.features.purchase.report;

import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.format.annotation.DateTimeFormat.ISO;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.List;

/**
 * 采购报表 API（采购管理，purchase_report:view）：
 *
 * - GET /api/purchase/reports/monthly?docType=&dateFrom=&dateTo=&limit= → 月度汇总（MV 上卷）
 * - GET /api/purchase/reports/pending?limit= → 待交货订货汇总
 *
 * <p>明细报表复用 /api/purchase/{requests|orders|receipts|returns} 列表（日期/供应商/状态过滤）。
 */
@RestController
@RequestMapping("/api/purchase/reports")
@RequiredArgsConstructor
public class PurchaseReportController {

    private final PurchaseReportService service;

    @GetMapping("/monthly")
    @PreAuthorize("hasAuthority('purchase_report:view')")
    public List<MonthlySummaryRow> monthly(
            @RequestParam(required = false) String docType,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "200") int limit) {
        return service.monthly(docType, dateFrom, dateTo, limit);
    }

    @GetMapping("/pending")
    @PreAuthorize("hasAuthority('purchase_report:view')")
    public List<PendingRow> pending(@RequestParam(defaultValue = "200") int limit) {
        return service.pending(limit);
    }
}
