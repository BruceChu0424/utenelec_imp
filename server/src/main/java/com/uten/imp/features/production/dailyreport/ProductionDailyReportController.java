package com.uten.imp.features.production.dailyreport;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.production.dailyreport.dto.DailyReportDetail;
import com.uten.imp.features.production.dailyreport.dto.DailyReportListItem;
import com.uten.imp.features.production.dailyreport.dto.DailyReportQueryFilter;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.format.annotation.DateTimeFormat.ISO;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.UUID;

/**
 * 生产日报 API（生产管理 · 空结构保未来）。
 *
 * <p>CRUD + 审核 + 红冲。本期审核仅置状态，<b>不调</b> {@code StockService}
 * （F_DateReport 老库从未启用，design §3.4；库存联动归未来车间/工序模块）。
 *
 * <ul>
 *   <li>GET    /api/production/daily-reports            列表分页</li>
 *   <li>GET    /api/production/daily-reports/{id}       详情（含明细）</li>
 *   <li>POST   /api/production/daily-reports            新建（草稿）</li>
 *   <li>PUT    /api/production/daily-reports/{id}       编辑（仅草稿）</li>
 *   <li>DELETE /api/production/daily-reports/{id}       软删（仅草稿/红冲）</li>
 *   <li>POST   /api/production/daily-reports/{id}/approve  审核（0→1，本期仅置状态）</li>
 *   <li>POST   /api/production/daily-reports/{id}/reverse  红冲（1→-1）</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/production/daily-reports")
@RequiredArgsConstructor
public class ProductionDailyReportController {

    private final ProductionDailyReportService service;
    private final ReportablePlanLineQueryService reportablePlanLines;

    @GetMapping("/reportable-plan-lines")
    @PreAuthorize("hasAuthority('production_daily_report:view')")
    public PageResponse<ReportablePlanLine> reportablePlanLines(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "30") int size,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(required = false) UUID executionSegmentId) {
        return reportablePlanLines.list(
                page, size, keyword, departmentId, executionSegmentId);
    }

    @GetMapping
    @PreAuthorize("hasAuthority('production_daily_report:view')")
    public PageResponse<DailyReportListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(required = false) UUID workerId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new DailyReportQueryFilter(keyword, warehouseId, departmentId, workerId,
                status, dateFrom, dateTo), page, size, sort, order);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('production_daily_report:view')")
    public DailyReportDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('production_daily_report:create')")
    public DailyReportDetail create(@Valid @RequestBody DailyReportSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('production_daily_report:edit')")
    public DailyReportDetail update(@PathVariable UUID id, @Valid @RequestBody DailyReportSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('production_daily_report:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('production_daily_report:approve')")
    public DailyReportDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('production_daily_report:reverse')")
    public DailyReportDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }
}
