package com.uten.imp.features.production.fulfillment;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.audit.AuditDetailViewRecorder;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.UUID;
import static com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryContracts.*;

@RestController
@RequestMapping("/api/production/material-discovery")
@RequiredArgsConstructor
public class ProductionMaterialDiscoveryController {
    private final ProductionMaterialDiscoveryService service;
    private final AuditDetailViewRecorder auditViews;
    @GetMapping("/segments/{id}") @PreAuthorize("hasAuthority('production_execution:view')")
    public Context context(@PathVariable UUID id){return service.context(id);}
    @PostMapping("/segments/{id}/request") @PreAuthorize("hasAuthority('production_execution:view') and hasAuthority('production_execution:start')")
    public Detail request(@PathVariable UUID id,@RequestBody Request command){return service.request(id,command);}
    @GetMapping("/requests") @PreAuthorize("hasAuthority('stock_doc:view')")
    public PageResponse<Detail> list(@RequestParam(defaultValue="PENDING") String status,@RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="20") int size){return service.list(status,page,size);}
    @GetMapping("/requests/{id}") @PreAuthorize("hasAnyAuthority('stock_doc:view','production_execution:view')")
    public Detail detail(@PathVariable UUID id){
        Detail result=service.detail(id);
        auditViews.record("view_production_material_discovery_detail","production_material_discovery_requests",id,result.segmentCode(),null,"最底层自制件实际领料");
        return result;
    }
    @PostMapping("/requests/{id}/materials") @PreAuthorize("hasAuthority('stock_doc:view') and hasAuthority('stock_doc:approve') and hasAuthority('stock_doc:issue')")
    public Detail configure(@PathVariable UUID id,@RequestBody Configure command){return service.configure(id,command);}
    @PostMapping("/requests/{id}/cancel") @PreAuthorize("hasAuthority('production_execution:view') and hasAuthority('production_execution:start')")
    public Detail cancel(@PathVariable UUID id,@RequestBody Request command){return service.cancel(id,command);}
}
