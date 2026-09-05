package com.uten.imp.features.production.execution;

import com.uten.imp.common.web.PageResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import java.util.Map;
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
            @RequestParam(required = false) String status) {
        return service.workshopTasks(page, size, keyword, status);
    }

    @GetMapping("/count")
    @PreAuthorize("hasAuthority('production_execution:view')")
    public Map<String, Long> count() {
        return Map.of("count", service.workshopTaskCount());
    }
}
