package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.MaterialStockOption;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PositionView;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/** 车间内料仓页: 现存、估计还剩、仓库可发与顶部的盘点结算状态。 */
@RestController
@RequestMapping("/api/workshop-material")
public class WorkshopMaterialPositionController {

    private final WorkshopMaterialPositionQueryService positions;

    public WorkshopMaterialPositionController(WorkshopMaterialPositionQueryService positions) {
        this.positions = positions;
    }

    @GetMapping("/bins/{binId}/position")
    @PreAuthorize("hasAuthority('workshop_material:view')")
    public PositionView position(@PathVariable UUID binId) {
        return positions.position(binId);
    }

    /** 可发到这个车间内料仓的料 (只列整批领料的料; 申请、发料与上线准备的下拉共用)。 */
    @GetMapping("/materials")
    @PreAuthorize("hasAuthority('workshop_material:view')")
    public List<MaterialStockOption> materials(@RequestParam UUID workshopId) {
        return positions.materials(workshopId);
    }
}
