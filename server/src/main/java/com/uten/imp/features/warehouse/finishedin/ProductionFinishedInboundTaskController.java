package com.uten.imp.features.warehouse.finishedin;

import com.uten.imp.common.web.PageResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/** Recoverable warehouse queue for production finished-in physical counts. */
@RestController
@RequestMapping("/api/warehouse/production-finished-in")
@RequiredArgsConstructor
public class ProductionFinishedInboundTaskController {

    private final ProductionFinishedInboundTaskService service;

    @GetMapping("/tasks")
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public PageResponse<ProductionFinishedInboundTask> tasks(
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "40") int size) {
        return service.list(keyword, page, size);
    }

    @GetMapping("/tasks/count")
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public Map<String, Long> count() {
        return Map.of("count", service.countPending());
    }
}
