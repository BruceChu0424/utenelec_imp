package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.ArrivalExceptionTask;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.InboundExpectationTask;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@RestController
@RequestMapping("/api/warehouse/inbound")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('warehouse_inbound:view')")
public class WarehouseInboundController {

    private final ProcurementArrivalControlService service;

    @GetMapping("/expectations")
    public PageResponse<InboundExpectationTask> expectations(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.expectations(page, size);
    }

    @GetMapping("/expectations/count")
    public Map<String, Long> expectationCount() {
        return Map.of("count", service.countExpectations());
    }

    @GetMapping("/arrival-exceptions")
    public PageResponse<ArrivalExceptionTask> arrivalExceptions(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.warehouseExceptions(page, size);
    }

    @GetMapping("/arrival-exceptions/count")
    public Map<String, Long> arrivalExceptionCount() {
        return Map.of("count", service.countWarehouseExceptions());
    }
}
