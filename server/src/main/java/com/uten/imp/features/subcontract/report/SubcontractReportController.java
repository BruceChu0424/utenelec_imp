package com.uten.imp.features.subcontract.report;

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
import java.util.UUID;

/**
 * 委外报表 API（委外管理，subcontract_report:view）：
 *
 * - GET /api/subcontract/reports/monthly?docType=&dateFrom=&dateTo=&limit= → 月度汇总（MV 上卷，覆盖 8 张汇总报表）
 * - GET /api/subcontract/reports/in-out-status?supplierId=&dateFrom=&dateTo=&limit= → 委外出入状况表（综合 O）
 *
 * <p><b>明细报表 ×8</b> 复用 {@code /api/subcontract/{doc}} 列表（日期/供应商/状态过滤），不在本端点重复。
 *
 * <p>docType 取值：INQUIRY / APPLICATION / ORDER / RECEIPT / RETURN /
 * MATERIAL_ISSUE / MATERIAL_RETURN / WASTE。
 */
@RestController
@RequestMapping("/api/subcontract/reports")
@RequiredArgsConstructor
public class SubcontractReportController {

    private final SubcontractReportService service;

    @GetMapping("/monthly")
    @PreAuthorize("hasAuthority('subcontract_report:view')")
    public List<SubcontractMonthlyRow> monthly(
            @RequestParam(required = false) String docType,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "200") int limit) {
        return service.monthly(docType, dateFrom, dateTo, limit);
    }

    @GetMapping("/in-out-status")
    @PreAuthorize("hasAuthority('subcontract_report:view')")
    public List<SubcontractInOutRow> inOutStatus(
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "200") int limit) {
        return service.inOutStatus(supplierId, dateFrom, dateTo, limit);
    }
}
