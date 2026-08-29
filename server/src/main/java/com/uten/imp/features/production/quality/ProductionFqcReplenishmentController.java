package com.uten.imp.features.production.quality;

import com.uten.imp.common.web.PageResponse;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Planning workbench bridge for SCRAP/REJECT replacement demand. */
@RestController
@RequestMapping("/api/production/quality-replenishments")
@RequiredArgsConstructor
public class ProductionFqcReplenishmentController {

    private final ProductionFqcReplenishmentService service;
    private final ProductionFqcReplenishmentMaterialService materialService;

    @GetMapping
    @PreAuthorize("hasAuthority('production_fqc_replenishment:view')"
            + " and hasAuthority('production_material_analysis:view')")
    public PageResponse<ProductionFqcReplenishmentService.ReplenishmentTaskView> pending(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "40") int size) {
        return service.pending(page, size);
    }

    @PostMapping("/{authorizationId}/material-analysis")
    @PreAuthorize("hasAuthority('production_fqc_replenishment:confirm')"
            + " and hasAuthority('production_material_analysis:create')")
    public ProductionFqcReplenishmentService.ReplenishmentTaskView createMaterialAnalysis(
            @PathVariable UUID authorizationId) {
        return service.createMaterialAnalysis(authorizationId);
    }

    @GetMapping("/material-tasks")
    @PreAuthorize("hasAuthority('production_fqc_replenishment:view')")
    public PageResponse<ProductionFqcReplenishmentMaterialService.MaterialTaskView>
            materialTasks(
                    @RequestParam(defaultValue = "1") int page,
                    @RequestParam(defaultValue = "40") int size) {
        return materialService.list(page, size);
    }

    @GetMapping("/material-tasks/count")
    @PreAuthorize("hasAuthority('production_fqc_replenishment:view')")
    public Map<String, Long> materialTaskCount() {
        return Map.of("count", materialService.countPending());
    }

    @PostMapping("/{authorizationId}/material-confirmations")
    @PreAuthorize("hasAuthority('production_fqc_replenishment:confirm')")
    public ProductionFqcReplenishmentMaterialService.MaterialTaskView
            confirmMaterial(
                    @PathVariable UUID authorizationId,
                    @Valid @RequestBody
                    ProductionFqcReplenishmentMaterialService.ConfirmRequest request) {
        return materialService.confirm(authorizationId, request);
    }
}
