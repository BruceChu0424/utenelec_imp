package com.uten.imp.features.stock.allocation;

import com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.*;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.List;
import java.util.Map;
import java.util.UUID;

@RestController
@RequiredArgsConstructor
@RequestMapping("/api/stock/production-materials")
public class ProductionMaterialReturnRequestController {
    private final ProductionMaterialReturnRequestService service;

    @GetMapping("/plans/{planId}/return-requests/sources")
    @PreAuthorize("hasAnyAuthority('production_plan:view','stock_doc:view','production_execution:view')")
    public List<Source> sources(@PathVariable UUID planId, @RequestParam UUID executionSegmentId) {
        return service.sources(planId, executionSegmentId);
    }
    @GetMapping("/plans/{planId}/return-requests")
    @PreAuthorize("hasAnyAuthority('production_plan:view','stock_doc:view','production_execution:view')")
    public List<Document> list(@PathVariable UUID planId, @RequestParam UUID executionSegmentId) {
        return service.list(planId, executionSegmentId);
    }
    @PostMapping("/plans/{planId}/return-requests")
    @PreAuthorize("hasAuthority('production_material:settle')")
    public List<Document> submit(@PathVariable UUID planId, @RequestBody Submit request) {
        return service.submit(planId, request);
    }
    @PostMapping("/plans/{planId}/return-requests/{documentId}/cancel")
    @PreAuthorize("hasAuthority('production_material:settle')")
    public Document cancel(@PathVariable UUID planId, @PathVariable UUID documentId, @RequestBody Cancel request) {
        return service.cancel(planId, documentId, request);
    }
    @GetMapping("/return-requests/warehouse/count")
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public Map<String, Long> count() { return Map.of("count", service.warehousePendingCount()); }
}
