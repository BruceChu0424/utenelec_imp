package com.uten.imp.features.sales.report;

import com.uten.imp.common.web.PageResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.format.annotation.DateTimeFormat.ISO;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 销售报表 API（销售管理，sales_report:view）：
 *
 * <p>明细报表 ×5（参数化）：
 * - GET /api/sales/reports/{docType}/detail?dateFrom=&dateTo=&clientId=&goodsId=&billNo=&status=&page=&size=
 *   docType ∈ { QUOTE, ORDER, SHIPMENT, OTHER_SHIPMENT, RETURN }
 *
 * <p>汇总报表（sales_monthly_mv 上卷，参数化；按 docType 过滤即 5 张汇总）：
 * - GET /api/sales/reports/monthly?docType=&dateFrom=&dateTo=&clientId=&goodsId=&limit=
 *
 * <p>待交货订货汇总（sales_order_pending_v）：
 * - GET /api/sales/reports/pending?limit=
 */
@RestController
@RequestMapping("/api/sales/reports")
@RequiredArgsConstructor
public class SalesReportController {

    private final SalesReportService service;

    /** 明细报表（5 单据类型参数化；docType 决定查哪张明细表）。 */
    @GetMapping("/{docType}/detail")
    @PreAuthorize("hasAuthority('sales_report:view')")
    public PageResponse<SalesDetailRow> detail(
            @PathVariable String docType,
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) UUID goodsId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.detail(docType, billNo, clientId, goodsId, status, dateFrom, dateTo, page, size);
    }

    /** 月度汇总（sales_monthly_mv；docType 过滤选 5 类之一或全部）。 */
    @GetMapping("/monthly")
    @PreAuthorize("hasAuthority('sales_report:view')")
    public List<MonthlySummaryRow> monthly(
            @RequestParam(required = false) String docType,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) UUID goodsId,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "200") int limit) {
        return service.monthly(docType, clientId, goodsId, dateFrom, dateTo, limit);
    }

    /** 待交货订货汇总（sales_order_pending_v：未发数量 = qty - shipped_qty + returned_qty - flag_qty > 0）。 */
    @GetMapping("/pending")
    @PreAuthorize("hasAuthority('sales_report:view')")
    public List<PendingRow> pending(
            @RequestParam(required = false) UUID clientId,
            @RequestParam(defaultValue = "200") int limit) {
        return service.pending(clientId, limit);
    }
}
