package com.uten.imp.features.warehouse.materialbin;

import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

@RestController
@RequestMapping("/api/workshop-material/segments")
public class WorkshopTaskMaterialStockController {
    private final WorkshopTaskMaterialStockQueryService service;

    public WorkshopTaskMaterialStockController(WorkshopTaskMaterialStockQueryService service) {
        this.service = service;
    }

    @GetMapping("/{segmentId}/stock-readiness")
    @PreAuthorize("hasAuthority('workshop_material:view')")
    public WorkshopTaskMaterialStockQueryService.StockReadiness readiness(@PathVariable UUID segmentId) {
        return service.readiness(segmentId);
    }
}
