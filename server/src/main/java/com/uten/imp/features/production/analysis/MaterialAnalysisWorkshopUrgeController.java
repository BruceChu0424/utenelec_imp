package com.uten.imp.features.production.analysis;

import com.uten.imp.features.production.execution.ProductionPlanningUrgeService;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 计划侧看车间催办(ADR-117)：物料分析页顶部「车间在催」提示条、下单后立即核对、计划员徽章。
 * 车间那一侧的「催计划」在 {@code /api/production/workshop-tasks/{segmentId}/planning-urge}。
 */
@RestController
@RequestMapping("/api/production/material-analyses")
@RequiredArgsConstructor
public class MaterialAnalysisWorkshopUrgeController {

    private final MaterialAnalysisPlanningGapReader planningGaps;
    private final ProductionPlanningUrgeService planningUrges;

    /**
     * 本分析上车间在催的任务：谁催的、催了几次、那个任务还缺哪几行。
     * 「计划还缺多少」由前端拿同一份分析快照的「还缺数量」判断，与主表同一个数。
     */
    @GetMapping("/{id}/workshop-urges")
    @PreAuthorize("hasAuthority('production_material_analysis:view')")
    public List<MaterialAnalysisPlanningGapReader.WorkshopUrgeView> workshopUrges(@PathVariable UUID id) {
        return planningGaps.urges(id);
    }

    /**
     * 计划员在本页下完单后立即核对一次在催记录：缺口已补上的办结并撤回待办卡，
     * 不必等后台 5 分钟一轮的核对。只动催办记录与通知，不改任何数量。
     */
    @PostMapping("/{id}/workshop-urges/reconcile")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and "
            + "(hasAuthority('production_material_analysis:notify') or hasAuthority('production_material_analysis:generate'))")
    public Map<String, Integer> reconcileWorkshopUrges(@PathVariable UUID id) {
        planningGaps.requireReadableAnalysis(id);
        return Map.of("resolved", planningUrges.reconcileAnalysis(id));
    }

    /** 计划员徽章：本人可见的物料分析上仍在催的车间任务数。 */
    @GetMapping("/workshop-urges/count")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and "
            + "(hasAuthority('production_material_analysis:notify') or hasAuthority('production_material_analysis:generate'))")
    public Map<String, Long> workshopUrgeCount() {
        return Map.of("count", planningGaps.openUrgeCount());
    }
}
