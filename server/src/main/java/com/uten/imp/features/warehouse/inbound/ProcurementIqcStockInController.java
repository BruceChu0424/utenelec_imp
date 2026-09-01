package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmResult;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.TaskDetail;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.TaskSummary;
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

/** Dedicated warehouse API; never returns purchase price, amount, currency or AP data. */
@RestController
@RequestMapping("/api/warehouse/iqc-stock-ins")
@RequiredArgsConstructor
public class ProcurementIqcStockInController {

    private final ProcurementIqcStockInService service;

    @GetMapping
    @PreAuthorize("hasAuthority('" + ProcurementIqcStockInPermissions.VIEW + "')")
    public PageResponse<TaskSummary> list(
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(defaultValue = "ALL") String receiptType,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "40") int size) {
        return service.list(keyword, receiptType, page, size);
    }

    @GetMapping("/count")
    @PreAuthorize("hasAuthority('" + ProcurementIqcStockInPermissions.VIEW + "')")
    public Map<String, Long> count() {
        return Map.of("count", service.countPending());
    }

    @GetMapping("/{receiptType}/{receiptId}")
    @PreAuthorize("hasAuthority('" + ProcurementIqcStockInPermissions.VIEW + "')")
    public TaskDetail detail(
            @PathVariable String receiptType,
            @PathVariable UUID receiptId) {
        return service.detail(receiptType, receiptId);
    }

    @PostMapping("/{receiptType}/{receiptId}/confirm")
    @PreAuthorize("hasAuthority('" + ProcurementIqcStockInPermissions.VIEW + "')"
            + " and hasAuthority('" + ProcurementIqcStockInPermissions.CONFIRM + "')")
    public ConfirmResult confirm(
            @PathVariable String receiptType,
            @PathVariable UUID receiptId,
            @Valid @RequestBody ConfirmRequest request) {
        return service.confirm(receiptType, receiptId, request);
    }
}
