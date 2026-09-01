package com.uten.imp.features.finance.payables.warehouse;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.RecordReturnRequest;
import jakarta.validation.Valid;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/**
 * Warehouse-only IQC physical-return API.  The list projection retired with the
 * 2026-09-01 merge into /warehouse/quality-results; this surface keeps only the
 * deep-link detail read and the return-voucher command.
 */
@RestController
@RequestMapping("/api/warehouse/iqc-returns")
public class WarehouseIqcReturnController {

    private final WarehouseIqcReturnProjectionService service;
    private final AuditDetailViewRecorder auditViews;

    public WarehouseIqcReturnController(
            WarehouseIqcReturnProjectionService service,
            AuditDetailViewRecorder auditViews) {
        this.service = service;
        this.auditViews = auditViews;
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('" + WarehouseIqcReturnPermissions.VIEW + "')")
    public WarehouseIqcReturnView detail(@PathVariable UUID id) {
        WarehouseIqcReturnView result = service.detail(id);
        String businessNo = result.receiptBillNo() == null
                ? result.orderBillNo() : result.receiptBillNo();
        auditViews.record(
                "view_procurement_iqc_rejection_detail",
                "procurement_iqc_rejection_cases",
                id,
                businessNo,
                null,
                "采购质检不合格实物退回");
        return result;
    }

    @PostMapping("/{id}/record-return")
    @PreAuthorize("hasAuthority('" + WarehouseIqcReturnPermissions.VIEW + "')"
            + " and hasAuthority('" + WarehouseIqcReturnPermissions.RECORD_RETURN + "')")
    public WarehouseIqcReturnView recordReturn(
            @PathVariable UUID id,
            @Valid @RequestBody RecordReturnRequest request) {
        return service.recordReturn(id, request);
    }
}
