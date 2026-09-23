package com.uten.imp.features.production.mrp;

import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/**
 * MRP-lite 接口：生产计划物料需求预览、下游草稿生成与计划包生命周期。
 * 每个写动作使用独立权限；production_plan:edit 仅保留给生产计划草稿本身编辑。
 *
 * <p>所有方法入口先过 {@link ProductionPlanResourceGuard}：计划子资源与计划详情同一对象范围，
 * 越权读 404、越权写 403(security-07)。
 */
@RestController
@RequestMapping("/api/production/plans")
@RequiredArgsConstructor
public class MrpController {

    private final MrpService mrpService;
    private final ProductionPlanningPackageService planningPackageService;
    private final ProductionPlanningDraftService planningDraftService;
    private final ProductionPlanResourceGuard planGuard;

    /** 物料需求预览（毛需求/库存/在途/净需求，自制件标记）。 */
    @GetMapping("/{id}/mrp")
    @PreAuthorize("hasAuthority('production_plan:view')")
    public List<MrpRow> preview(@PathVariable UUID id) {
        planGuard.requireReadable(id);
        return mrpService.preview(id);
    }

    /** 已生成的自制件子计划溯源（父计划 MRP 面板展示，可跳子计划详情）。 */
    @GetMapping("/{id}/mrp/subplans")
    @PreAuthorize("hasAuthority('production_plan:view')")
    public List<MrpService.SubplanRef> subplans(@PathVariable UUID id) {
        planGuard.requireReadable(id);
        return mrpService.subplans(id);
    }

    /**
     * 原子生成计划包：用户校对后的子计划，以及可选的缺料采购申请。
     * 任一校验或写入失败时整包回滚，不留下半套单据。
     */
    @PostMapping("/{id}/mrp/generate-planning-package")
    @PreAuthorize("hasAuthority('production_planning_package:generate')")
    public PlanningPackageResult generatePlanningPackage(
            @PathVariable UUID id,
            @jakarta.validation.Valid @org.springframework.web.bind.annotation.RequestBody
            GeneratePlanningPackageRequest req) {
        planGuard.requireWritable(id, "production_planning_package:generate");
        return planningPackageService.confirm(id, req);
    }

    /** 生成领料单请求体。 */
    @GetMapping("/{id}/mrp/planning-preview")
    @PreAuthorize("hasAuthority('production_plan:view')")
    public PlanningPreviewResult planningPreview(
            @PathVariable UUID id,
            @org.springframework.web.bind.annotation.RequestParam UUID warehouseId) {
        planGuard.requireReadable(id);
        return planningPackageService.preview(id, warehouseId);
    }

    @PutMapping("/{id}/mrp/planning-draft")
    @PreAuthorize("hasAuthority('production_planning_package:draft_edit')")
    public ProductionPlanningDraftView savePlanningDraft(
            @PathVariable UUID id,
            @jakarta.validation.Valid
            @org.springframework.web.bind.annotation.RequestBody
            GeneratePlanningPackageRequest request) {
        planGuard.requireWritable(id, "production_planning_package:draft_edit");
        return planningDraftService.save(id, request);
    }

    @GetMapping("/{id}/mrp/planning-draft")
    @PreAuthorize("hasAuthority('production_plan:view')")
    public ResponseEntity<ProductionPlanningDraftView> currentPlanningDraft(
            @PathVariable UUID id) {
        planGuard.requireReadable(id);
        return planningDraftService.current(id)
                .map(ResponseEntity::ok)
                .orElseGet(() -> ResponseEntity.notFound().build());
    }

    @GetMapping("/{id}/mrp/planning-package-result")
    @PreAuthorize("hasAuthority('production_plan:view')")
    public ResponseEntity<PlanningPackageResult> currentPlanningPackageResult(
            @PathVariable UUID id) {
        planGuard.requireReadable(id);
        return planningPackageService.currentResult(id)
                .map(ResponseEntity::ok)
                .orElseGet(() -> ResponseEntity.notFound().build());
    }

    @PostMapping("/{id}/mrp/planning-packages/{packageId}/cancel")
    @PreAuthorize("hasAuthority('production_planning_package:cancel')")
    public PlanningPackageLifecycleResult cancelPlanningPackage(
            @PathVariable UUID id,
            @PathVariable UUID packageId,
            @jakarta.validation.Valid
            @org.springframework.web.bind.annotation.RequestBody
            PlanningPackageLifecycleRequest request) {
        planGuard.requireWritable(id, "production_planning_package:cancel");
        return planningPackageService.cancel(id, packageId, request);
    }

    @PostMapping("/{id}/mrp/planning-packages/{packageId}/reverse")
    @PreAuthorize("hasAuthority('production_planning_package:reverse')")
    public PlanningPackageLifecycleResult reversePlanningPackage(
            @PathVariable UUID id,
            @PathVariable UUID packageId,
            @jakarta.validation.Valid
            @org.springframework.web.bind.annotation.RequestBody
            PlanningPackageLifecycleRequest request) {
        planGuard.requireWritable(id, "production_planning_package:reverse");
        return planningPackageService.reverse(id, packageId, request);
    }
}
