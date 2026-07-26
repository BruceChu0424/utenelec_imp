package com.uten.imp.features.sales.report;

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
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 销售报表 API（销售管理 / 销售报表，sales_report:view）。
 *
 * <p>8 张报表（服务端 JOIN 出名称 + 分页 + 列 facet 筛选）—— **报价无报表**：
 * <ul>
 *   <li>GET /{docType}/detail  /{docType}/summary   订货/出货/退货/其它出货 各明细/汇总</li>
 * </ul>
 * docType ∈ { ORDER, SHIPMENT, OTHER_SHIPMENT, RETURN }（无 QUOTE）。
 *
 * <p>通用参数：billNo / clientId / warehouseId / status / dateFrom / dateTo / keyword / page / size。
 * 列筛选以 {@code f.<colKey>=<value>} 传（值 {@code __null__} 表空值档）。
 *
 * <p>保留：/monthly（MV 上卷，迁末已刷新）、/pending（待交货订货汇总视图）。
 */
@RestController
@RequestMapping("/api/sales/reports")
@RequiredArgsConstructor
public class SalesReportController {

    private final SalesReportService service;

    /** 明细报表（4 单据类型参数化；docType 决定查哪张明细表 + 列集）。 */
    @GetMapping("/{docType}/detail")
    @PreAuthorize("hasAuthority('sales_report:view')")
    public ReportTableResponse detail(
            @PathVariable String docType,
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.detail(docType, billNo, clientId, warehouseId, status, dateFrom, dateTo, keyword,
                facetsOf(allParams), page, size);
    }

    /** 汇总报表（4 单据类型参数化；一行一单号）。 */
    @GetMapping("/{docType}/summary")
    @PreAuthorize("hasAuthority('sales_report:view')")
    public ReportTableResponse summary(
            @PathVariable String docType,
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.summary(docType, billNo, clientId, warehouseId, status, dateFrom, dateTo, keyword,
                facetsOf(allParams), page, size);
    }

    /** 从全部查询参数里抽出列筛选（键以 "f." 前缀）。 */
    private static Map<String, String> facetsOf(Map<String, String> allParams) {
        Map<String, String> facets = new HashMap<>();
        if (allParams == null) return facets;
        for (Map.Entry<String, String> e : allParams.entrySet()) {
            if (e.getKey().startsWith("f.") && e.getValue() != null && !e.getValue().isBlank()) {
                facets.put(e.getKey().substring(2), e.getValue());
            }
        }
        return facets;
    }

    // ---------- 保留：月度汇总 / 待交货 ----------

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

    @GetMapping("/pending")
    @PreAuthorize("hasAuthority('sales_report:view')")
    public List<PendingRow> pending(
            @RequestParam(required = false) UUID clientId,
            @RequestParam(defaultValue = "200") int limit) {
        return service.pending(clientId, limit);
    }
}
