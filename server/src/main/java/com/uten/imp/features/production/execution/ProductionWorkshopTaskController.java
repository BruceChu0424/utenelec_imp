package com.uten.imp.features.production.execution;

import com.uten.imp.common.web.PageResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import java.time.LocalDate;
import java.util.Map;
import java.util.UUID;
import org.springframework.web.bind.annotation.RestController;

/** Workshop-facing task list. It never exposes unassigned production rows. */
@RestController
@RequestMapping("/api/production/workshop-tasks")
@RequiredArgsConstructor
public class ProductionWorkshopTaskController {

    private final ProductionExecutionWorkbenchService service;

    @GetMapping
    @PreAuthorize("hasAuthority('production_execution:view')")
    public PageResponse<ProductionExecutionWorkbenchSegment> list(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) UUID workshopDepartmentId,
            @RequestParam(required = false) LocalDate dateFrom,
            @RequestParam(required = false) LocalDate dateTo) {
        // dateFrom/dateTo 只对「历史任务」段生效（ADR-066 §1.3 时间门控：
        // 已完工/已取消/已红冲按计划完工日期筛选）；活动段忽略日期参数。
        return service.workshopTasks(page, size, keyword, status,
                workshopDepartmentId, dateFrom, dateTo);
    }

    @GetMapping("/count")
    @PreAuthorize("hasAuthority('production_execution:view')")
    public Map<String, Long> count() {
        ProductionExecutionWorkbenchService.WorkshopTaskCountBreakdown breakdown =
                service.workshopTaskCountBreakdown();
        // count 保持旧字段（总徽章消费者不变），同时给出与顶部分类一致的互斥分段计数
        //（等待物料 + 生产中 = 总数；「可报工」分段 2026-09-06 退役，2026-09-10 删字段）。
        return Map.of(
                "count", breakdown.total(),
                "preparing", breakdown.preparing(),
                "inProgress", breakdown.inProgress());
    }
}
