package com.uten.imp.features.production.execution;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.PageResponse;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.Map;
import java.util.UUID;

import static com.uten.imp.features.production.execution.ProductionOverproductionRateContracts.*;

@RestController
@RequestMapping("/api/production/overproduction-rate")
@RequiredArgsConstructor
public class ProductionOverproductionRateController {
    private final ProductionOverproductionRateService service;
    private final AuditDetailViewRecorder auditViews;

    @GetMapping("/segments/{id}")
    @PreAuthorize("hasAnyAuthority('production_execution:view','production_plan:approve')")
    public RateContext context(@PathVariable UUID id) { return service.context(id); }

    @PostMapping("/requests")
    @PreAuthorize("hasAuthority('production_execution:view') and hasAuthority('production_execution:request_overproduction_rate')")
    public RequestView submit(@Valid @RequestBody SubmitRequest request) { return service.submit(request); }

    @GetMapping("/requests")
    @PreAuthorize("hasAuthority('production_plan:approve')")
    public PageResponse<RequestView> list(@RequestParam(defaultValue="PENDING") String status,
            @RequestParam(defaultValue="1") int page, @RequestParam(defaultValue="20") int size) {
        return service.list(status,page,size);
    }

    @GetMapping("/count")
    @PreAuthorize("hasAuthority('production_plan:approve')")
    public Map<String,Long> count() { return Map.of("count",service.count()); }

    @GetMapping("/requests/{id}")
    @PreAuthorize("hasAnyAuthority('production_execution:view','production_plan:approve')")
    public RequestView detail(@PathVariable UUID id) {
        RequestView result = service.detail(id);
        auditViews.record(
                "view_production_overproduction_rate_detail",
                "production_overproduction_rate_requests",
                id,
                result.segmentCode(),
                null,
                "超产比例申请");
        return result;
    }

    @PostMapping("/requests/{id}/approve")
    @PreAuthorize("hasAuthority('production_plan:approve')")
    public RequestView approve(@PathVariable UUID id,@Valid @RequestBody DecisionRequest request) {
        return service.decide(id,request,true);
    }

    @PostMapping("/requests/{id}/return")
    @PreAuthorize("hasAuthority('production_plan:approve')")
    public RequestView reject(@PathVariable UUID id,@Valid @RequestBody DecisionRequest request) {
        return service.decide(id,request,false);
    }
}
