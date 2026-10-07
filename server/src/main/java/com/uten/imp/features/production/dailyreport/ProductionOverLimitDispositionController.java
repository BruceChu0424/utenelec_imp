package com.uten.imp.features.production.dailyreport;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.PageResponse;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.Map;
import java.util.UUID;
import static com.uten.imp.features.production.dailyreport.ProductionOverLimitDispositionContracts.*;

@RestController
@RequestMapping("/api/production/over-limit-dispositions")
@RequiredArgsConstructor
public class ProductionOverLimitDispositionController {
    private final ProductionOverLimitDispositionService service;
    private final AuditDetailViewRecorder auditViews;
    @GetMapping
    @PreAuthorize("hasAuthority('production_plan:approve')")
    public PageResponse<View> list(@RequestParam(defaultValue="PENDING") String status,
            @RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="20") int size){return service.list(status,page,size);}
    @GetMapping("/count")
    @PreAuthorize("hasAuthority('production_plan:approve')")
    public Map<String,Long> count(){return Map.of("count",service.count());}
    @GetMapping("/{id}")
    @PreAuthorize("hasAnyAuthority('production_plan:approve','production_plan:view','production_execution:view','production_daily_report:view')")
    public View detail(@PathVariable UUID id){
        View result=service.detail(id);
        auditViews.record("view_production_over_limit_detail","production_over_limit_dispositions",id,
            result.segmentCode(),null,"超限产出处置");
        return result;
    }
    @PostMapping("/{id}/decisions")
    @PreAuthorize("hasAuthority('production_plan:approve')")
    public View decide(@PathVariable UUID id,@Valid @RequestBody DecisionRequest request){return service.decide(id,request);}
}
