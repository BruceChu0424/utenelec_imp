package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

@RestController
@RequestMapping("/api/workshop-material/task-status")
public class WorkshopMaterialTaskStatusController {
    private final WorkshopMaterialSettingsService settings;
    private final WarehouseTaskScopePort warehouseScopes;

    public WorkshopMaterialTaskStatusController(WorkshopMaterialSettingsService settings, WarehouseTaskScopePort warehouseScopes) {
        this.settings = settings;
        this.warehouseScopes = warehouseScopes;
    }

    @GetMapping
    @PreAuthorize("hasAuthority('workshop_material:view')")
    public List<WorkshopMaterialDtos.SettingsView> list(@RequestParam(required = false) UUID scopeWarehouseId) {
        return warehouseScopes.withQueryScopeCache(() -> settings.taskStatus(warehouseScopes.current(scopeWarehouseId)));
    }
}
