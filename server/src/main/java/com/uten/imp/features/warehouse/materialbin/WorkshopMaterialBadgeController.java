package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.BadgeCounts;
import org.springframework.security.access.prepost.PreAuthorize;
import com.uten.imp.application.port.WarehouseTaskScopePort;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/**
 * 车间内料仓的工作台徽章计数 (ADR-108 约定: 一个来源 = 一个带权限的计数端点)。
 * 待发料计入出库的生产领料，待收退回计入入库的生产退料；周期盘点中仍为内料仓进行中数。
 */
@RestController
@RequestMapping("/api/workshop-material")
public class WorkshopMaterialBadgeController {

    private final WorkshopMaterialPositionQueryService positions;
    private final WarehouseTaskScopePort warehouseScopes;

    public WorkshopMaterialBadgeController(WorkshopMaterialPositionQueryService positions,
                                           WarehouseTaskScopePort warehouseScopes) {
        this.positions = positions;
        this.warehouseScopes = warehouseScopes;
    }

    /** 徽章来源 workshopMaterial: 与请领列表同一仓库数据范围(ADR-149, 预填叶仓; 盘点中按内料仓来源仓)。 */
    @GetMapping("/badge-counts")
    @com.uten.imp.security.BusinessTaskRead
    @PreAuthorize("hasAuthority('workshop_material:view')")
    public BadgeCounts badgeCounts(@RequestParam(required = false) UUID scopeWarehouseId) {
        return positions.badgeCounts(warehouseScopes.current(scopeWarehouseId));
    }
}
