package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.BatchConfirmRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.BatchConfirmResult;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmResult;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.TaskDetail;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/**
 * Dedicated warehouse API; never returns purchase price, amount, currency or AP data.
 * The paged queue list/count retired with the 2026-09-01 merge into
 * /warehouse/quality-results; this surface keeps the deep-link detail read plus
 * the single and batch confirmation commands.
 */
@RestController
@RequestMapping("/api/warehouse/iqc-stock-ins")
@RequiredArgsConstructor
public class ProcurementIqcStockInController {

    private final ProcurementIqcStockInService service;

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

    /** 跨收货单批量入库（品质部检查结果页多选办理）：整批同事务，任一冲突整批回滚。 */
    @PostMapping("/batch-confirm")
    @PreAuthorize("hasAuthority('" + ProcurementIqcStockInPermissions.VIEW + "')"
            + " and hasAuthority('" + ProcurementIqcStockInPermissions.CONFIRM + "')")
    public BatchConfirmResult batchConfirm(
            @Valid @RequestBody BatchConfirmRequest request) {
        return service.batchConfirm(request);
    }
}
