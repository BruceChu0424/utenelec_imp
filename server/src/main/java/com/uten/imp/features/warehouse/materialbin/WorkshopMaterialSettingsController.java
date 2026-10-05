package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.BatchDisableRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.BatchEnableRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.BatchResult;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PendingChoiceList;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.SettingsRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.SettingsView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.SourceWarehouseOption;
import jakarta.validation.constraints.Size;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.validation.annotation.Validated;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/**
 * 车间内料仓开通与整批领料 (ADR-147)。
 *
 * <ul>
 *   <li>GET  /api/workshop-material/settings                       车间清单 + 三态 (未开通/已开通/整批领料中)</li>
 *   <li>GET  /api/workshop-material/settings/source-warehouses     发料来源仓滑窗的仓库层级 (只有元数据)</li>
 *   <li>GET  /api/workshop-material/settings/in-progress-pending   这些车间在产还没认料的产品 (按产品去重)</li>
 *   <li>POST /api/workshop-material/settings/batch-enable          批量开通 / 开启整批领料 / 改来源仓 (全成全败)</li>
 *   <li>POST /api/workshop-material/settings/batch-disable         批量撤销一步 (全成全败)</li>
 *   <li>PUT  /api/workshop-material/settings/{workshopId}          单车间, 与批量同一条代码路径</li>
 * </ul>
 */
@Validated
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

    /** Warehouse hierarchy metadata only (no balances, keepers or administration fields). */
    @GetMapping("/source-warehouses")
    @PreAuthorize("hasAnyAuthority('workshop_material:setup','workshop_material:issue')")
    public List<SourceWarehouseOption> sourceWarehouses() {
        return settings.sourceWarehouses();
    }

    @GetMapping("/in-progress-pending")
    @PreAuthorize("hasAuthority('workshop_material:setup')")
    public PendingChoiceList inProgressPending(
            @RequestParam("workshopIds") @Size(max = WorkshopMaterialSettingsService.BATCH_LIMIT) List<UUID> workshopIds) {
        return settings.inProgressPending(workshopIds);
    }

    @PostMapping("/batch-enable")
    @PreAuthorize("hasAuthority('workshop_material:setup')")
    public BatchResult batchEnable(@jakarta.validation.Valid @RequestBody BatchEnableRequest request) {
        return settings.batchEnable(request);
    }

    @PostMapping("/batch-disable")
    @PreAuthorize("hasAuthority('workshop_material:setup')")
    public BatchResult batchDisable(@jakarta.validation.Valid @RequestBody BatchDisableRequest request) {
        return settings.batchDisable(request);
    }

    @PutMapping("/{workshopId}")
    @PreAuthorize("hasAuthority('workshop_material:setup')")
    public SettingsView update(@PathVariable UUID workshopId, @jakarta.validation.Valid @RequestBody SettingsRequest request) {
        return settings.update(workshopId, request);
    }
}
