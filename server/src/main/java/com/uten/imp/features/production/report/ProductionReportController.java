package com.uten.imp.features.production.report;

import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.format.annotation.DateTimeFormat.ISO;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 生产报表 API（生产管理，production_report:view）。
 *
 * <p>生产计划 2 张报表（服务端 JOIN 出名称 + 分页 + 列 facet 筛选，范式同采购/销售报表）：
 * <ul>
 *   <li>GET /api/production/reports/plan/detail?billNo=&goodsId=&status=&dateFrom=&dateTo=&keyword=&page=&size=
 *       — 生产计划明细（一行=单里一样货品，货品/类别/颜色名称服务端 JOIN）</li>
 *   <li>GET /api/production/reports/plan/summary?billNo=&status=&dateFrom=&dateTo=&keyword=&page=&size=
 *       — 生产计划汇总（一行=一整张单，制单员/审核员名 COALESCE(employees, 冻结名)）</li>
 * </ul>
 *
 * <p>通用参数：billNo / goodsId(仅明细) / status / dateFrom / dateTo / keyword / page / size。
 * 列筛选以 {@code f.<colKey>=<value>} 传（值 {@code __null__} 表空值档）。
 *
 * <p>保留：/daily/detail、/daily/summary（生产日报 <b>本期 0 行</b>，结构留位；前端未挂入口）。
 */
@RestController
@RequestMapping("/api/production/reports")
@RequiredArgsConstructor
public class ProductionReportController {

    private final ProductionReportService service;

    // ===== 生产计划（PLAN） =====

    @GetMapping("/plan/detail")
    @PreAuthorize("hasAuthority('production_report:view')")
    public ReportTableResponse planDetail(
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID goodsId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.planDetail(billNo, goodsId, status, dateFrom, dateTo, keyword, facetsOf(allParams), page, size);
    }

    @GetMapping("/plan/summary")
    @PreAuthorize("hasAuthority('production_report:view')")
    public ReportTableResponse planSummary(
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.planSummary(billNo, status, dateFrom, dateTo, keyword, facetsOf(allParams), page, size);
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

    // ===== 生产日报（DAILY · 本期 0 行，结构留位；前端未挂入口） =====

    @GetMapping("/daily/detail")
    @PreAuthorize("hasAuthority('production_report:view')")
    public List<DailyDetailRow> dailyDetail(
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) UUID goodsId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) String billNo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.dailyDetail(dateFrom, dateTo, goodsId, status, billNo, page, size);
    }

    @GetMapping("/daily/summary")
    @PreAuthorize("hasAuthority('production_report:view')")
    public List<MonthlySummaryRow> dailySummary(
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "200") int limit) {
        return service.monthly("DAILY", dateFrom, dateTo, limit);
    }
}
