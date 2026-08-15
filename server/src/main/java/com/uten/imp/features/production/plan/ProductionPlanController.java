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
 * <p>负责计划草稿、审核、红冲及进度查询。审核会校验并落地销售订单分摊，
 * 回写计划数量和业务链状态，重算 {@code is_closed}，并通过业务 Outbox 发布排产通知。
 * 计划单本身不直接过账库存或应收应付；领料、成品入库和报工由各自单据处理。
 *
 * <ul>
 *   <li>GET    /api/production/plans            列表分页（关键词/部门/状态/结案/日期）</li>
 *   <li>GET    /api/production/plans/{id}       详情（含明细）</li>
 *   <li>POST   /api/production/plans            新建（草稿）</li>
 *   <li>PUT    /api/production/plans/{id}       编辑（仅草稿）</li>
 *   <li>DELETE /api/production/plans/{id}       软删（仅草稿/红冲）</li>
 *   <li>POST   /api/production/plans/{id}/approve  审核（0→1 + 销售来源联动）</li>
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

    /**
     * 生产进度看板（服务端分页）：closed=false 进行中（默认）/ true 已完成；父计划带子计划嵌套进度。
     * sort=billDate（开单远→近，默认）| billDateDesc | deliveryDate | progress；
     * keyword 模糊单号/车间；workshop 精确；dateFrom/dateTo 开单日期范围。
     */
    @GetMapping("/progress")
    @PreAuthorize("hasAuthority('production_plan:view')")
    public PageResponse<com.uten.imp.features.production.plan.dto.PlanProgressRow> progress(
            @RequestParam(defaultValue = "false") boolean closed,
            @RequestParam(required = false) String sort,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) String workshop,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo) {
        return service.progress(closed, sort, page, size, keyword, workshop, dateFrom, dateTo);
    }

    /** 进度看板汇总（同过滤、跨全部页）：count / sumQty / sumInbound。 */
    @GetMapping("/progress/summary")
    @PreAuthorize("hasAuthority('production_plan:view')")
    public java.util.Map<String, Object> progressSummary(
            @RequestParam(defaultValue = "false") boolean closed,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) String workshop,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo) {
        return service.progressSummary(closed, keyword, workshop, dateFrom, dateTo);
    }

    /** 进度看板车间筛选选项（去重车间名）。 */
    @GetMapping("/progress/workshops")
    @PreAuthorize("hasAuthority('production_plan:view')")
    public java.util.List<java.util.Map<String, String>> progressWorkshops(
            @RequestParam(defaultValue = "false") boolean closed) {
        return service.progressWorkshops(closed);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('production_plan:view')")
    public PlanDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('production_plan:edit')")
    public PlanDetail create(@Valid @RequestBody PlanSaveRequest req) {
        throw new com.uten.imp.common.web.ApiException(
                com.uten.imp.common.web.ErrorCode.CONFLICT,
                "新增生产计划必须先完成物料分析，请使用 /api/production/material-analyses");
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
    @PreAuthorize("hasAuthority('production_plan:approve')")
    public PlanDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('production_plan:edit')")
    public PlanDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }

    /** 看板标记：置顶 / 重要，null 字段不变。 */
    @PostMapping("/{id}/flags")
    @PreAuthorize("hasAuthority('production_plan:edit')")
    public void flags(@PathVariable UUID id,
                      @RequestBody com.uten.imp.features.production.plan.dto.PlanFlagsRequest req) {
        service.updateFlags(id, req);
    }
}
