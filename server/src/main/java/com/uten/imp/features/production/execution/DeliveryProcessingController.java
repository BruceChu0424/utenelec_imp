package com.uten.imp.features.production.execution;

import com.uten.imp.common.web.PageResponse;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;
import static com.uten.imp.features.production.execution.DeliveryProcessingContracts.*;

@RestController
@RequestMapping("/api/production/delivery-processing-tasks")
@RequiredArgsConstructor
public class DeliveryProcessingController {
    private final DeliveryProcessingService service;

    @GetMapping
    @PreAuthorize("hasAuthority('production_execution:view')")
    public PageResponse<Task> list(@RequestParam(defaultValue="1") int page,
            @RequestParam(defaultValue="50") int size, @RequestParam(required=false) UUID shipmentId,
            @RequestParam(required=false) String status, @RequestParam(required=false) String keyword) {
        return service.list(page,size,shipmentId,status,keyword);
    }

    @GetMapping("/{componentId}")
    @PreAuthorize("hasAuthority('production_execution:view')")
    public Task get(@PathVariable UUID componentId) { return service.get(componentId); }

    @GetMapping("/{componentId}/requests/{requestId}")
    @PreAuthorize("hasAuthority('production_execution:view')")
    public ActionOutcome requestOutcome(@PathVariable UUID componentId,@PathVariable UUID requestId) {
        return service.outcome(componentId,requestId);
    }

    @GetMapping("/{componentId}/warehouses")
    @PreAuthorize("hasAuthority('production_execution:view')")
    public java.util.List<com.uten.imp.application.port.SalesDeliveryInventoryPort.Choice> warehouses(@PathVariable UUID componentId) {
        return service.warehouses(componentId);
    }

    @PostMapping("/{componentId}/assignment")
    @PreAuthorize("hasAuthority('production_execution:view') and hasAuthority('production_execution:assign')")
    public Task assign(@PathVariable UUID componentId,@Valid @RequestBody Assignment request) {
        return service.assign(componentId,request);
    }

    @PostMapping("/{componentId}/start")
    @PreAuthorize("hasAuthority('production_execution:view') and hasAuthority('production_execution:start')")
    public Task start(@PathVariable UUID componentId,@Valid @RequestBody Start request) {
        return service.start(componentId,request);
    }

    @PostMapping("/{componentId}/reports")
    @PreAuthorize("hasAuthority('production_execution:view') and hasAuthority('production_daily_report:create')")
    public Task report(@PathVariable UUID componentId,@Valid @RequestBody Report request) {
        return service.report(componentId,request);
    }

    @PostMapping("/{componentId}/cancel-start")
    @PreAuthorize("hasAuthority('production_execution:view') and hasAuthority('production_execution:start')")
    public Task cancelStart(@PathVariable UUID componentId,@Valid @RequestBody CancelStart request) {
        return service.cancelStart(componentId,request);
    }
}
