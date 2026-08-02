package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.ArrivalDecisionRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.ArrivalExceptionTask;
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

@RestController
@RequestMapping("/api/finance/procurement-arrival-exceptions")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('finance_order_approval:view')")
public class FinanceProcurementArrivalExceptionController {

    private final ProcurementArrivalControlService service;

    @GetMapping("/tasks")
    public PageResponse<ArrivalExceptionTask> tasks(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.financeTasks(page, size);
    }

    @GetMapping("/count")
    public Map<String, Long> count() {
        return Map.of("count", service.countFinanceTasks());
    }

    @GetMapping("/{id}")
    public ArrivalExceptionTask detail(@PathVariable UUID id) {
        return service.financeDetail(id);
    }

    @PostMapping("/{id}/decision")
    @PreAuthorize("hasAuthority('finance_order_approval:view') and "
            + "hasAuthority('finance_order_approval:review')")
    public ArrivalExceptionTask decide(
            @PathVariable UUID id,
            @Valid @RequestBody ArrivalDecisionRequest request) {
        return service.financeDecide(id, request);
    }
}
