package com.uten.imp.features.production.quality;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.production.quality.ProductionFqcContracts.DecisionRequest;
import com.uten.imp.features.production.quality.ProductionFqcContracts.DecisionResult;
import com.uten.imp.features.production.quality.ProductionFqcContracts.InspectionView;
import com.uten.imp.features.production.quality.ProductionFqcContracts.PassAllBatchRequest;
import com.uten.imp.features.production.quality.ProductionFqcContracts.PassAllBatchResult;
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

import java.util.Map;
import java.util.UUID;

/** Production final-quality inspection workbench API. */
@RestController
@RequestMapping("/api/production/quality-inspections")
@RequiredArgsConstructor
public class ProductionFqcInspectionController {

    private final ProductionFqcInspectionService service;
    private final ProductionFqcTaskAccessPolicy taskAccess;
    private final AuditDetailViewRecorder auditViews;

    @GetMapping
    @PreAuthorize("hasAuthority('production_quality_inspection:view')")
    public PageResponse<InspectionView> list(
            @RequestParam(required = false) String status,
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "40") int size) {
        return service.list(status, keyword, page, size);
    }

    @GetMapping("/count")
    @PreAuthorize("hasAuthority('production_quality_inspection:view')")
    public Map<String, Long> count() {
        return Map.of("count", service.countActive());
    }

    @GetMapping("/capability")
    @PreAuthorize("hasAuthority('production_quality_inspection:view')")
    public Map<String, Boolean> capability() {
        return Map.of(
                "canDecide", taskAccess.canAccessQualityPool());
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('production_quality_inspection:view')")
    public InspectionView detail(@PathVariable UUID id) {
        InspectionView result = service.detail(id);
        auditViews.record(
                "view_production_fqc_inspection_detail",
                "production_fqc_inspections",
                id,
                result.reportNo(),
                null,
                "生产终检任务");
        return result;
    }

    @PostMapping("/decisions/pass-all")
    @PreAuthorize("hasAuthority('production_quality_inspection:view')"
            + " and hasAuthority('production_quality_inspection:approve')")
    public PassAllBatchResult passAll(
            @Valid @RequestBody PassAllBatchRequest request) {
        return service.passAll(request);
    }

    @PostMapping("/{id}/decisions")
    @PreAuthorize("hasAuthority('production_quality_inspection:view')"
            + " and hasAuthority('production_quality_inspection:approve')")
    public DecisionResult decide(
            @PathVariable UUID id,
            @Valid @RequestBody DecisionRequest request) {
        return service.decide(id, request);
    }
}
