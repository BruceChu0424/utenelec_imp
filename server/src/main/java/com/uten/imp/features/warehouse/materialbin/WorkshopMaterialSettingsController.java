package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PendingChoiceList;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.SettingsRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.SettingsView;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/** 车间整批领料设置 (ADR-131 §5.1 第 3 步)。 */
@RestController
@RequestMapping("/api/workshop-material/settings")
public class WorkshopMaterialSettingsController {

    private final WorkshopMaterialSettingsService settings;

    public WorkshopMaterialSettingsController(WorkshopMaterialSettingsService settings) {
        this.settings = settings;
    }

    @GetMapping
    @PreAuthorize("hasAnyAuthority('workshop_material:view','workshop_material:setup')")
    public List<SettingsView> list() {
        return settings.list();
    }

    /** Only placement metadata for the setup flow; this does not expose the warehouse dictionary or stock. */
    @GetMapping("/main-warehouses")
    @PreAuthorize("hasAuthority('workshop_material:setup')")
    public List<Map<String,Object>> mainWarehouses() {
        return settings.mainWarehouses();
    }

    /** 开启 (取得或建出内料仓、建第 1 期、在产产品一次认完并绑定) 或停用 (只撤销设错的开启)。 */
    @PutMapping("/{workshopId}")
    @PreAuthorize("hasAuthority('workshop_material:setup')")
    public SettingsView update(@PathVariable UUID workshopId, @RequestBody SettingsRequest request) {
        return settings.update(workshopId, request);
    }

    @GetMapping("/{workshopId}/in-progress-pending")
    @PreAuthorize("hasAuthority('workshop_material:setup')")
    public PendingChoiceList inProgressPending(@PathVariable UUID workshopId) {
        return settings.inProgressPending(workshopId);
    }
}
