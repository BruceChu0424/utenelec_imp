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
import java.util.List;
import java.util.UUID;

/**
 * 生产报表 API（生产管理，production_report:view）：
 *
 * <ul>
 *   <li>GET /api/production/reports/plan/detail?dateFrom=&dateTo=&goodsId=&status=&billNo=&page=&size=
 *       — 生产计划明细（参数化分页，不走 MV）</li>
 *   <li>GET /api/production/reports/plan/summary?dateFrom=&dateTo=&limit=
 *       — 生产计划汇总（MV WHERE doc_type='PLAN'，按 货品/月 上卷）</li>
 *   <li>GET /api/production/reports/daily/detail?...&page=&size=
 *       — 生产日报明细（<b>本期 0 行</b>，结构留位）</li>
 *   <li>GET /api/production/reports/daily/summary?...&limit=
 *       — 生产日报汇总（MV WHERE doc_type='DAILY'，<b>本期 0 行</b>）</li>
 * </ul>
 *
 * <p>生产计划列表（含状态/结案过滤）复用 /api/production/plans 列表入口；本报表入口聚焦"跨单据明细 + 汇总"。
 */
@RestController
@RequestMapping("/api/production/reports")
@RequiredArgsConstructor
public class ProductionReportController {

    private final ProductionReportService service;

    // ===== 生产计划（PLAN） =====

    @GetMapping("/plan/detail")
    @PreAuthorize("hasAuthority('production_report:view')")
    public List<PlanDetailRow> planDetail(
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) UUID goodsId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) String billNo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.planDetail(dateFrom, dateTo, goodsId, status, billNo, page, size);
    }

    @GetMapping("/plan/summary")
    @PreAuthorize("hasAuthority('production_report:view')")
    public List<MonthlySummaryRow> planSummary(
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "200") int limit) {
        return service.monthly("PLAN", dateFrom, dateTo, limit);
    }

    // ===== 生产日报（DAILY · 本期 0 行，结构留位） =====

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
