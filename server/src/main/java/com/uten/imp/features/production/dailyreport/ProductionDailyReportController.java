package com.uten.imp.features.production.dailyreport;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
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
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
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
    private final AuditDetailViewRecorder auditViews;

    @GetMapping("/reportable-plan-lines")
    @PreAuthorize("hasAuthority('production_daily_report:view')")
    public PageResponse<ReportablePlanLine> reportablePlanLines(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "30") int size,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(required = false) UUID executionSegmentId,
            @RequestParam(required = false) String executionSegmentIds) {
        List<UUID> exactSegmentIds = normalizeExecutionSegmentIds(
                executionSegmentId, executionSegmentIds);
        return reportablePlanLines.list(
                page, size, keyword, departmentId, exactSegmentIds);
    }

    /**
     * Accepts the current comma-separated client shape and the historical
     * singular parameter. Order is stable, duplicates collapse, and the
     * server enforces the same bounded batch size for every caller.
     */
    static List<UUID> normalizeExecutionSegmentIds(
            UUID executionSegmentId, String executionSegmentIds) {
        LinkedHashSet<UUID> normalized = new LinkedHashSet<>();
        if (executionSegmentId != null) normalized.add(executionSegmentId);
        if (executionSegmentIds != null && !executionSegmentIds.isBlank()) {
            String[] tokens = executionSegmentIds.split(",", -1);
            for (String token : tokens) {
                String value = token.strip();
                if (value.isEmpty()) {
                    throw new ApiException(
                            ErrorCode.VALIDATION_FAILED,
                            "批量报工执行段 UUID 清单包含空值");
                }
                try {
                    normalized.add(UUID.fromString(value));
                } catch (IllegalArgumentException error) {
                    throw new ApiException(
                            ErrorCode.VALIDATION_FAILED,
                            "批量报工执行段 UUID 格式无效");
                }
            }
        }
        if (normalized.size() > 100) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "一次最多选择 100 个执行工单进行批量报工");
        }
        return List.copyOf(new ArrayList<>(normalized));
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
        DailyReportDetail result = service.detail(id);
        auditViews.record(
                "view_production_daily_report_detail",
                "production_daily_reports",
                id,
                result.getBillNo(),
                result.getLegacyId(),
                "生产日报");
        return result;
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
