package com.uten.imp.features.production.plan;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.production.plan.dto.PlanDetail;
import com.uten.imp.features.production.plan.dto.PlanListItem;
import com.uten.imp.features.production.plan.dto.PlanQueryFilter;
import com.uten.imp.features.production.plan.dto.PlanSaveRequest;
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
 * 生产计划 API（生产管理）。
 *
 * <p>CRUD + 审核 + 红冲。审核仅置 status=1 + 重算 is_closed；
 * <b>不</b>调库存 / 立帐 / 回写销售订单（design §4.1 本期后置清单）。
 *
 * <ul>
 *   <li>GET    /api/production/plans            列表分页（关键词/部门/状态/结案/日期）</li>
 *   <li>GET    /api/production/plans/{id}       详情（含明细）</li>
 *   <li>POST   /api/production/plans            新建（草稿）</li>
 *   <li>PUT    /api/production/plans/{id}       编辑（仅草稿）</li>
 *   <li>DELETE /api/production/plans/{id}       软删（仅草稿/红冲）</li>
 *   <li>POST   /api/production/plans/{id}/approve  审核（0→1 + 派生 is_closed）</li>
 *   <li>POST   /api/production/plans/{id}/reverse  红冲（1→-1）</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/production/plans")
@RequiredArgsConstructor
public class ProductionPlanController {

    private final ProductionPlanService service;

    @GetMapping
    @PreAuthorize("hasAuthority('production_plan:view')")
    public PageResponse<PlanListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) Boolean closed,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new PlanQueryFilter(keyword, departmentId, status, closed, dateFrom, dateTo), page, size, sort, order);
    }

    /** 生产进度看板：closed=false 进行中（默认）/ closed=true 已完成；父计划带子计划嵌套进度。 */
    @GetMapping("/progress")
    @PreAuthorize("hasAuthority('production_plan:view')")
    public java.util.List<com.uten.imp.features.production.plan.dto.PlanProgressRow> progress(
            @RequestParam(defaultValue = "false") boolean closed) {
        return service.progress(closed);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('production_plan:view')")
    public PlanDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('production_plan:edit')")
    public PlanDetail create(@Valid @RequestBody PlanSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('production_plan:edit')")
    public PlanDetail update(@PathVariable UUID id, @Valid @RequestBody PlanSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('production_plan:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('production_plan:edit')")
    public PlanDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('production_plan:edit')")
    public PlanDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }
}
