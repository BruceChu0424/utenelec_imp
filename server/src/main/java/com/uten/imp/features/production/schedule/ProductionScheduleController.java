package com.uten.imp.features.production.schedule;

import com.uten.imp.features.production.schedule.dto.MergePlanRequest;
import com.uten.imp.features.production.schedule.dto.PendingPlanRow;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 生产调度工作台 API（业务链 · 排产段）。
 *
 * <p>GET  /pending      待排产订单行（交货升序，urgent 标红）—— production_plan:view
 * <p>POST /merge-plan   合并排产创建草稿计划（同货合并行 + 预建 links）—— production_plan:edit
 */
@RestController
@RequestMapping("/api/production/schedule")
@RequiredArgsConstructor
public class ProductionScheduleController {

    private final ProductionScheduleService service;

    @GetMapping("/pending")
    @PreAuthorize("hasAuthority('production_plan:view')")
    public List<PendingPlanRow> pending() {
        return service.pending();
    }

    /** 待排产计数（生产部工作台徽标）：{"count": n, "urgent": m}。 */
    @GetMapping("/pending-count")
    @PreAuthorize("hasAuthority('production_plan:view')")
    public Map<String, Long> pendingCount() {
        return service.pendingCount();
    }

    /** 缺料待备料计数（PMC 采购管理徽标）：{"count": n}；生产/采购两侧都可查。 */
    @GetMapping("/shortage-count")
    @PreAuthorize("hasAnyAuthority('production_plan:view','purchase_request:view')")
    public Map<String, Long> shortageCount() {
        return service.shortageCount();
    }

    /** 已审订单明细 + 每行货品一层 BOM 零件（新建计划单「从订单带明细」弹窗数据源）。 */
    @GetMapping("/order-lines")
    @PreAuthorize("hasAuthority('production_plan:view')")
    public List<com.uten.imp.features.production.schedule.dto.ScheduleOrderLine> orderLines(
            @RequestParam UUID orderId) {
        return service.orderLines(orderId);
    }

    /** 返回 {"planId": "..."}，前端跳计划详情页确认后审核。 */
    @PostMapping("/merge-plan")
    @PreAuthorize("hasAuthority('production_plan:edit')")
    public Map<String, UUID> mergePlan(@Valid @RequestBody MergePlanRequest req) {
        return Map.of("planId", service.createMergePlan(req));
    }

    /** D2 建议完工日期：body {items:[{goodsId,qty}], startDate?} → suggestedDate + 逐货品依据。 */
    @PostMapping("/suggest-finish")
    @PreAuthorize("hasAuthority('production_plan:view')")
    @SuppressWarnings("unchecked")
    public Map<String, Object> suggestFinish(@RequestBody Map<String, Object> body) {
        List<Map<String, Object>> items = (List<Map<String, Object>>) body.getOrDefault("items", List.of());
        java.time.LocalDate start = body.get("startDate") == null
                ? null : java.time.LocalDate.parse(body.get("startDate").toString());
        return service.suggestFinish(items, start);
    }
}
