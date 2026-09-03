package com.uten.imp.features.warehouse.finishedin;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationView;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.BatchArrivalRegistrationRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.BatchArrivalRegistrationResult;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.BatchRememberPlacesResult;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.LastWarehouseView;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.PlaceSuggestionsView;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.RememberPlacesResult;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Recoverable warehouse queue for production finished-in physical counts. */
@RestController
@RequestMapping("/api/warehouse/production-finished-in")
@RequiredArgsConstructor
public class ProductionFinishedInboundTaskController {

    private final ProductionFinishedInboundTaskService service;
    private final ProductionFinishedArrivalRegistrationService arrivalRegistrations;

    @GetMapping("/tasks")
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public PageResponse<ProductionFinishedInboundTask> tasks(
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "40") int size) {
        return service.list(keyword, page, size);
    }

    @GetMapping("/tasks/count")
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public Map<String, Long> count() {
        return Map.of("count", service.countPending());
    }

    // 批量端点须声明在 /{reportId} 之前：同前缀下字面量路径优先匹配，多单汇总入口
    // 不会被当作 reportId 解析。
    @GetMapping("/arrival-registrations/batch")
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public List<ArrivalRegistrationView> batchArrivalRegistrations(
            @RequestParam List<UUID> reportIds) {
        return arrivalRegistrations.batchDetail(reportIds);
    }

    @GetMapping("/arrival-registrations/batch/place-suggestions")
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public PlaceSuggestionsView batchPlaceSuggestions(
            @RequestParam List<UUID> reportIds,
            @RequestParam UUID warehouseId) {
        return arrivalRegistrations.batchPlaceSuggestions(reportIds, warehouseId);
    }

    @PostMapping("/arrival-registrations/batch")
    @PreAuthorize("hasAuthority('stock_doc:view')"
            + " and hasAuthority('stock_doc:approve')")
    public BatchArrivalRegistrationResult registerArrivalBatch(
            @Valid @RequestBody BatchArrivalRegistrationRequest request) {
        return arrivalRegistrations.batchRegister(request);
    }

    @PostMapping("/arrival-registrations/batch/remember-places")
    @PreAuthorize("hasAuthority('stock_doc:view')"
            + " and hasAuthority('stock_doc:approve')")
    public BatchRememberPlacesResult rememberPlacesBatch(
            @RequestBody List<UUID> reportIds) {
        return arrivalRegistrations.rememberPlacesBatch(reportIds);
    }

    @GetMapping("/arrival-registrations/last-warehouse")
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public LastWarehouseView lastArrivalWarehouse() {
        return arrivalRegistrations.lastWarehouse();
    }

    @GetMapping("/arrival-registrations/{reportId}")
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public ArrivalRegistrationView arrivalRegistration(
            @PathVariable UUID reportId) {
        return arrivalRegistrations.detail(reportId);
    }

    @GetMapping("/arrival-registrations/{reportId}/place-suggestions")
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public PlaceSuggestionsView placeSuggestions(
            @PathVariable UUID reportId,
            @RequestParam UUID warehouseId) {
        return arrivalRegistrations.placeSuggestions(reportId, warehouseId);
    }

    @PostMapping("/arrival-registrations/{reportId}")
    @PreAuthorize("hasAuthority('stock_doc:view')"
            + " and hasAuthority('stock_doc:approve')")
    public ArrivalRegistrationView registerArrival(
            @PathVariable UUID reportId,
            @Valid @RequestBody ArrivalRegistrationRequest request) {
        return arrivalRegistrations.register(reportId, request);
    }

    @PostMapping("/arrival-registrations/{reportId}/remember-places")
    @PreAuthorize("hasAuthority('stock_doc:view')"
            + " and hasAuthority('stock_doc:approve')")
    public RememberPlacesResult rememberPlaces(
            @PathVariable UUID reportId) {
        return arrivalRegistrations.rememberPlaces(reportId);
    }
}
