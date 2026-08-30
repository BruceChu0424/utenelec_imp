package com.uten.imp.features.production.analysis;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.validation.RequestLimits;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.production.mrp.GoodsWorkshopPreferenceView;
import com.uten.imp.features.production.mrp.ProductionGoodsWorkshopPreferenceService;
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

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;

/** HTTP boundary for persistent pre-plan material analysis. */
@RestController
@RequestMapping("/api/production/material-analyses")
@RequiredArgsConstructor
public class MaterialAnalysisController {

    private final MaterialAnalysisService queryService;
    private final MaterialAnalysisCommandService commandService;
    private final MaterialStockReallocationService stockReallocationService;
    private final ProductionGoodsWorkshopPreferenceService workshopPreferences;
    private final MaterialAnalysisSupplyProgressService supplyProgressService;
    private final AuditDetailViewRecorder detailViewAudit;

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

    /** Learned defaults used only to prefill a new planning draft. */
    @GetMapping("/default-workshops")
    @PreAuthorize("hasAuthority('production_material_analysis:view')")
    public List<GoodsWorkshopPreferenceView> defaultWorkshops(
            @RequestParam("ids") Set<UUID> ids) {
        if (ids == null || ids.isEmpty()
                || ids.size() > RequestLimits.LOOKUP_IDS) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "货品 ID 数量必须为 1-" + RequestLimits.LOOKUP_IDS);
        }
        return workshopPreferences.findValidByGoodsIds(ids);
    }

    @PostMapping("/preview")
    @PreAuthorize("""
            (#request.analysisId == null and hasAuthority('production_material_analysis:create'))
            or (#request.analysisId != null and hasAuthority('production_material_analysis:refresh'))
            """)
    public AnalysisView preview(@Valid @RequestBody PreviewRequest request) {
        return queryService.preview(request);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('production_material_analysis:view')")
    public AnalysisView detail(@PathVariable UUID id) {
        AnalysisView result = queryService.detail(id);
        detailViewAudit.record(
                "view_material_analysis_detail", "production_material_analyses", id,
                null, null, "物料分析");
        return result;
    }

    /** 物料节点供给全链路进度（只读）：下单/财务/收货/质检/入库逐步状态。 */
    @GetMapping("/{id}/materials/{materialLineId}/supply-progress")
    @PreAuthorize("hasAuthority('production_material_analysis:view')")
    public SupplyProgressView supplyProgress(
            @PathVariable UUID id,
            @PathVariable UUID materialLineId) {
        return supplyProgressService.supplyProgress(id, materialLineId);
    }

    @GetMapping("/{id}/materials/{materialLineId}/cross-reallocation-candidates")
    @PreAuthorize("hasAuthority('production_material_analysis:cross_reallocate')")
    public PageResponse<CrossReallocationCandidate> crossReallocationCandidates(
            @PathVariable UUID id,
            @PathVariable UUID materialLineId,
            @RequestParam(required = false) String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return stockReallocationService.candidates(
                id, materialLineId, keyword, page, size);
    }

    @PostMapping("/{id}/cross-reallocations")
    @PreAuthorize("hasAuthority('production_material_analysis:cross_reallocate')")
    public AnalysisView createCrossReallocation(
            @PathVariable UUID id,
            @Valid @RequestBody CrossReallocationRequest request) {
        return stockReallocationService.create(id, request);
    }

    @PostMapping("/{id}/cross-reallocations/{reallocationId}/revoke")
    @PreAuthorize("hasAuthority('production_material_analysis:cross_reallocate')")
    public AnalysisView revokeCrossReallocation(
            @PathVariable UUID id,
            @PathVariable UUID reallocationId,
            @Valid @RequestBody CrossReallocationRevokeRequest request) {
        return stockReallocationService.revoke(id, reallocationId, request);
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

    /** 现货层借用（调货）：把一条直接组件路径的已分配覆盖量调给另一产品同物料路径。 */
    @PostMapping("/{id}/borrows")
    @PreAuthorize("hasAuthority('production_material_analysis:reallocate')")
    public AnalysisView createBorrow(
            @PathVariable UUID id,
            @Valid @RequestBody BorrowRequest request) {
        return queryService.createBorrow(id, request);
    }

    /** 撤销一笔 ACTIVE 借用，恢复基线分配投影。 */
    @PostMapping("/{id}/borrows/{borrowId}/revoke")
    @PreAuthorize("hasAuthority('production_material_analysis:reallocate')")
    public AnalysisView revokeBorrow(
            @PathVariable UUID id,
            @PathVariable UUID borrowId,
            @Valid @RequestBody CancelRequest request) {
        return queryService.revokeBorrow(id, borrowId, request);
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
    @PreAuthorize("hasAuthority('production_material_analysis:cancel')")
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
