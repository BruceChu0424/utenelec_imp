package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.BadgeCounts;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 车间内料仓的工作台徽章计数 (ADR-108 约定: 一个来源 = 一个带权限的计数端点)。
 * 仓库任务中心「车间内料仓」: 红 = 待发料 + 待收退回, 黄 = 盘点中。
 */
@RestController
@RequestMapping("/api/workshop-material")
public class WorkshopMaterialBadgeController {

    private final WorkshopMaterialPositionQueryService positions;

    public WorkshopMaterialBadgeController(WorkshopMaterialPositionQueryService positions) {
        this.positions = positions;
    }

    @GetMapping("/badge-counts")
    @PreAuthorize("hasAuthority('workshop_material:view')")
    public BadgeCounts badgeCounts() {
        return positions.badgeCounts();
    }
}
