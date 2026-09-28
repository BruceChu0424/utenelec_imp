package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.CancelRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.DirectIssueDefaults;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.DirectIssueRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.FulfilRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.OtherIssueRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.OtherIssueView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.RequisitionCreate;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.RequisitionView;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/** 车间内料仓的领料、退回、直接发料与其它耗用 (ADR-131 §5.2、§5.3)。 */
@RestController
@RequestMapping("/api/workshop-material")
public class WorkshopMaterialRequisitionController {

    private final WorkshopMaterialRequisitionService requisitions;
    private final WorkshopMaterialOtherIssueService otherIssues;
    private final WarehouseTaskScopePort warehouseScopes;

    public WorkshopMaterialRequisitionController(WorkshopMaterialRequisitionService requisitions,
                                                 WorkshopMaterialOtherIssueService otherIssues,
                                                 WarehouseTaskScopePort warehouseScopes) {
        this.requisitions = requisitions;
        this.otherIssues = otherIssues;
        this.warehouseScopes = warehouseScopes;
    }

    /** 仓库方可按"我负责的仓库"过滤 (按预填叶仓)。 */
    @GetMapping("/requisitions")
    @PreAuthorize("hasAuthority('workshop_material:view')")
    public PageResponse<RequisitionView> list(@RequestParam(required = false) String status,
                                              @RequestParam(required = false) String kind,
                                              @RequestParam(required = false) UUID workshopId,
                                              @RequestParam(defaultValue = "") String warehouseScope,
                                              @RequestParam(required = false) UUID scopeWarehouseId,
                                              @RequestParam(defaultValue = "1") int page,
                                              @RequestParam(defaultValue = "20") int size) {
        return requisitions.list(status, kind, workshopId, warehouseScopes.resolve(warehouseScope, scopeWarehouseId),
                page, size);
    }

    @GetMapping("/requisitions/{requisitionId}")
    @PreAuthorize("hasAuthority('workshop_material:view')")
    public RequisitionView detail(@PathVariable UUID requisitionId) {
        return requisitions.detail(requisitionId);
    }

    @PostMapping("/requisitions")
    @PreAuthorize("hasAuthority('workshop_material:request')")
    public RequisitionView create(@RequestBody RequisitionCreate request) {
        return requisitions.create(request);
    }

    @PostMapping("/requisitions/{requisitionId}/fulfil")
    @PreAuthorize("hasAuthority('workshop_material:issue')")
    public RequisitionView fulfil(@PathVariable UUID requisitionId, @RequestBody FulfilRequest request) {
        return requisitions.fulfil(requisitionId, request);
    }

    @PostMapping("/requisitions/{requisitionId}/cancel")
    @PreAuthorize("hasAnyAuthority('workshop_material:request','workshop_material:issue')")
    public RequisitionView cancel(@PathVariable UUID requisitionId, @RequestBody CancelRequest request) {
        return requisitions.cancel(requisitionId, request);
    }

    /** 仓库直接发料 (主路径); supplement 非空 = 补录到盘点中或已盘点、还没结算的那一期。 */
    @PostMapping("/direct-issues")
    @PreAuthorize("hasAuthority('workshop_material:issue')")
    public RequisitionView directIssue(@RequestBody DirectIssueRequest request) {
        return requisitions.directIssue(request);
    }

    @GetMapping("/direct-issues/defaults")
    @PreAuthorize("hasAuthority('workshop_material:issue')")
    public DirectIssueDefaults defaults(@RequestParam UUID workshopId) {
        return requisitions.defaults(workshopId);
    }

    @PostMapping("/other-issues")
    @PreAuthorize("hasAuthority('workshop_material:request')")
    public OtherIssueView otherIssue(@RequestBody OtherIssueRequest request) {
        return otherIssues.create(request);
    }
}
