package com.uten.imp.features.stock.report;

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
import java.util.Map;
import java.util.UUID;

/**
 * 仓库报表 API（仓库管理 / 仓库报表，stock_report:view）。
 *
 * <p>14 张报表（服务端 JOIN 出名称 + 分页 + 列 facet 筛选），7 单据类型 × 明细/汇总：
 * <ul>
 *   <li>GET /{docType}/detail  /{docType}/summary   调拨/其它入库/领料/退料/产成品进仓/出仓/盘点 各明细/汇总</li>
 * </ul>
 * docType ∈ { TRANSFER, OTHER_IN, DRAW, WDRAW, FINISHED_IN, FINISHED_OUT, CHECK }（无 OTHER_OUT/WASTE，用户指定删除）。
 *
 * <p>通用参数：billNo / warehouseId / clientId / status / dateFrom / dateTo / keyword / page / size。
 * 列筛选以 {@code f.<colKey>=<value>} 传（值 {@code __null__} 表空值档）。
 *
 * <p>明细表：一行=单里一样货品（同单号重复）；汇总表：一行=一整张单（单号唯一）。
 */
@RestController
@RequestMapping("/api/stock/reports")
@RequiredArgsConstructor
public class StockReportController {

    private final StockReportService service;

    /** 明细报表（7 单据类型参数化；docType 决定列集 + 标签）。 */
    @GetMapping("/{docType}/detail")
    @PreAuthorize("hasAuthority('stock_report:view')")
    public ReportTableResponse detail(
            @PathVariable String docType,
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.detail(docType, billNo, warehouseId, clientId, status, dateFrom, dateTo, keyword,
                facetsOf(allParams), page, size);
    }

    /** 汇总报表（7 单据类型参数化；一行一单号）。 */
    @GetMapping("/{docType}/summary")
    @PreAuthorize("hasAuthority('stock_report:view')")
    public ReportTableResponse summary(
            @PathVariable String docType,
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.summary(docType, billNo, warehouseId, clientId, status, dateFrom, dateTo, keyword,
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
}
