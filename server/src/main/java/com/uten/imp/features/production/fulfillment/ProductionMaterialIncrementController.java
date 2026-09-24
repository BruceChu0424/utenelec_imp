package com.uten.imp.features.production.fulfillment;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.PageResponse;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.Map;
import java.util.UUID;
import static com.uten.imp.features.production.fulfillment.ProductionMaterialIncrementContracts.*;

@RestController
@RequestMapping("/api/production/material-increments")
@RequiredArgsConstructor
public class ProductionMaterialIncrementController {
    private final ProductionMaterialIncrementService service;
    private final AuditDetailViewRecorder auditViews;
    @GetMapping("/segments/{id}/context")
    @PreAuthorize("hasAnyAuthority('production_execution:view','production_plan:approve')")
    public Context context(@PathVariable UUID id){return service.context(id);}
    @PostMapping("/requests")
    @PreAuthorize("hasAuthority('production_execution:view') and hasAuthority('production_execution:request_material_increment')")
    public RequestView submit(@Valid @RequestBody SubmitRequest request){return service.submit(request);}
    @GetMapping("/requests") @PreAuthorize("hasAuthority('production_plan:approve')")
    public PageResponse<RequestView> list(@RequestParam(defaultValue="PENDING") String status,
            @RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="20") int size){return service.list(status,page,size);}
    @GetMapping("/count") @PreAuthorize("hasAuthority('production_plan:approve')")
    public Map<String,Long> count(){return Map.of("count",service.count());}
    @GetMapping("/requests/{id}") @PreAuthorize("hasAnyAuthority('production_execution:view','production_plan:approve')")
    public RequestView detail(@PathVariable UUID id){
        RequestView result=service.detail(id);
        auditViews.record(
                "view_production_material_increment_detail",
                "production_material_increment_requests",
                id,
                result.segmentCode(),
                null,
                "追加用料申请");
        return result;
    }
    @PostMapping("/requests/{id}/approve") @PreAuthorize("hasAuthority('production_plan:approve')")
    public RequestView approve(@PathVariable UUID id,@Valid @RequestBody DecisionRequest request){return service.decide(id,request,true);}
    @PostMapping("/requests/{id}/return") @PreAuthorize("hasAuthority('production_plan:approve')")
    public RequestView reject(@PathVariable UUID id,@Valid @RequestBody DecisionRequest request){return service.decide(id,request,false);}
    @PostMapping("/requests/{id}/cancel") @PreAuthorize("hasAuthority('production_plan:approve')")
    public RequestView cancel(@PathVariable UUID id,@Valid @RequestBody DecisionRequest request){return service.cancel(id,request);}
}
