package com.uten.imp.features.warehouse.finishedin;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationView;
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
