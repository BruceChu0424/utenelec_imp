package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.PageResponse;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;

/** HTTP boundary for persistent pre-plan material analysis. */
@RestController
@RequestMapping("/api/production/material-analyses")
@RequiredArgsConstructor
public class MaterialAnalysisController {

    private final MaterialAnalysisService queryService;
    private final MaterialAnalysisCommandService commandService;

    @GetMapping
    @PreAuthorize("hasAuthority('production_material_analysis:view')")
    public PageResponse<AnalysisListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) String sourceType,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return queryService.list(keyword, status, sourceType, page, size);
    }

    @GetMapping("/sales-candidates")
    @PreAuthorize("hasAuthority('production_material_analysis:view')")
    public SalesCandidatePage salesCandidates(
            @RequestParam(required = false) String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return queryService.salesCandidates(keyword, page, size);
    }

    @PostMapping("/preview")
    @PreAuthorize("hasAuthority('production_material_analysis:manage')")
    public AnalysisView preview(@Valid @RequestBody PreviewRequest request) {
        return queryService.preview(request);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('production_material_analysis:view')")
    public AnalysisView detail(@PathVariable UUID id) {
        return queryService.detail(id);
    }

    @PutMapping("/{id}/routes")
    @PreAuthorize("hasAuthority('production_material_analysis:route')")
    public AnalysisView saveRoutes(
            @PathVariable UUID id,
            @Valid @RequestBody RouteRequest request) {
        return queryService.saveRoutes(id, request);
    }

    @PutMapping("/{id}/allocation-priorities")
    @PreAuthorize("hasAuthority('production_material_analysis:reallocate')")
    public AnalysisView saveAllocationPriorities(
            @PathVariable UUID id,
            @Valid @RequestBody AllocationPriorityRequest request) {
        return queryService.saveAllocationPriorities(id, request);
    }

    @PostMapping("/{id}/notify")
    @PreAuthorize("hasAuthority('production_material_analysis:notify')")
    public AnalysisView notifySupply(
            @PathVariable UUID id,
            @Valid @RequestBody NotifyRequest request) {
        return commandService.notifySupply(id, request);
    }

    @PostMapping("/{id}/plan-preview")
    @PreAuthorize("hasAuthority('production_material_analysis:generate')")
    public PlanPreview planPreview(
            @PathVariable UUID id,
            @Valid @RequestBody PlanPreviewRequest request) {
        return queryService.planPreview(id, request);
    }

    @PostMapping("/{id}/generate-plan")
    @PreAuthorize("hasAuthority('production_material_analysis:generate')")
    public GenerateResult generatePlan(
            @PathVariable UUID id,
            @Valid @RequestBody GeneratePlanRequest request) {
        return commandService.generatePlan(id, request);
    }

    @PostMapping("/{id}/cancel")
    @PreAuthorize("hasAuthority('production_material_analysis:manage')")
    public AnalysisView cancelAnalysis(
            @PathVariable UUID id,
            @Valid @RequestBody CancelRequest request) {
        return commandService.cancelAnalysis(id, request);
    }

    @PostMapping("/{id}/actions/{actionId}/cancel")
    @PreAuthorize("hasAuthority('production_material_analysis:notify')")
    public AnalysisView cancelAction(
            @PathVariable UUID id,
            @PathVariable UUID actionId,
            @Valid @RequestBody CancelRequest request) {
        return commandService.cancelAction(id, actionId, request);
    }
}
