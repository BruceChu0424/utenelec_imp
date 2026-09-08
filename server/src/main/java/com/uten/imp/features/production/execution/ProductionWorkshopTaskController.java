package com.uten.imp.features.production.execution;

import com.uten.imp.common.web.PageResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
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
            @RequestParam(required = false) UUID workshopDepartmentId) {
        return service.workshopTasks(page, size, keyword, status,
                workshopDepartmentId);
    }

    @GetMapping("/count")
    @PreAuthorize("hasAuthority('production_execution:view')")
    public Map<String, Long> count() {
        ProductionExecutionWorkbenchService.WorkshopTaskCountBreakdown breakdown =
                service.workshopTaskCountBreakdown();
        // count 保持旧字段（总徽章消费者不变），同时给出与顶部分类一致的互斥分段计数。
        return Map.of(
                "count", breakdown.total(),
                "preparing", breakdown.preparing(),
                "readyToReport", breakdown.readyToReport(),
                "inProgress", breakdown.inProgress());
    }
}
