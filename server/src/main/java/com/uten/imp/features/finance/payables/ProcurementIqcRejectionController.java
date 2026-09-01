package com.uten.imp.features.finance.payables;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.CaseCounts;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.CaseDetail;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.CaseItem;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.CasePage;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.CloseNoCreditRequest;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.ConfirmCreditRequest;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.RecordReturnRequest;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.ReverseRequest;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.RetryFinanceProjectionRequest;
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

import java.util.UUID;

@RestController
@RequestMapping("/api/procurement/iqc-rejections")
@RequiredArgsConstructor
public class ProcurementIqcRejectionController {
    private final ProcurementIqcRejectionService service;
    private final AuditDetailViewRecorder detailViewAudit;

    @GetMapping
    @PreAuthorize("hasAuthority('procurement_iqc_rejection:view')")
    public CasePage list(
            @RequestParam(required = false) String receiptType,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.list(receiptType, status, keyword, page, size);
    }

    @GetMapping("/counts")
    @PreAuthorize("hasAuthority('procurement_iqc_rejection:view')")
    public CaseCounts counts(
            @RequestParam(required = false) String receiptType,
            @RequestParam(required = false) String keyword) {
        return service.counts(receiptType, keyword);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('procurement_iqc_rejection:view')")
    public CaseDetail detail(@PathVariable UUID id) {
        CaseDetail result = service.detail(id);
        CaseItem caseItem = result.caseItem();
        String businessNo = caseItem == null ? null : caseItem.receiptBillNo();
        if ((businessNo == null || businessNo.isBlank()) && caseItem != null) {
            businessNo = caseItem.orderBillNo();
        }
        detailViewAudit.record(
                "view_procurement_iqc_rejection_detail",
                "procurement_iqc_rejection_cases",
                id,
                businessNo,
                null,
                "采购质检不合格闭环");
        return result;
    }

    @PostMapping("/{id}/record-return")
    @PreAuthorize("hasAuthority('procurement_iqc_rejection:view')"
            + " and hasAuthority('procurement_iqc_rejection:record_return')")
    public CaseDetail recordReturn(
            @PathVariable UUID id,
            @Valid @RequestBody RecordReturnRequest request) {
        return service.recordReturn(id, request);
    }

    @PostMapping("/{id}/confirm-credit")
    @PreAuthorize("hasAuthority('procurement_iqc_rejection:view')"
            + " and hasAuthority('procurement_iqc_rejection:confirm_credit')"
            + " and hasAuthority('procurement_iqc_rejection:amount:view')")
    public CaseDetail confirmCredit(
            @PathVariable UUID id,
            @Valid @RequestBody ConfirmCreditRequest request) {
        return service.confirmCredit(id, request);
    }

    @PostMapping("/{id}/close-no-credit")
    @PreAuthorize("hasAuthority('procurement_iqc_rejection:view')"
            + " and hasAuthority('procurement_iqc_rejection:close_no_credit')")
    public CaseDetail closeNoCredit(
            @PathVariable UUID id,
            @Valid @RequestBody CloseNoCreditRequest request) {
        return service.closeNoCredit(id, request);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('procurement_iqc_rejection:view')"
            + " and hasAuthority('procurement_iqc_rejection:reverse')")
    public CaseDetail reverse(
            @PathVariable UUID id,
            @Valid @RequestBody ReverseRequest request) {
        return service.reverse(id, request);
    }

    @PostMapping("/{id}/retry-finance-projection")
    @PreAuthorize("hasAuthority('procurement_iqc_rejection:view')"
            + " and hasAuthority('procurement_iqc_rejection:confirm_credit')"
            + " and hasAuthority('procurement_iqc_rejection:amount:view')")
    public CaseDetail retryFinanceProjection(
            @PathVariable UUID id,
            @Valid @RequestBody RetryFinanceProjectionRequest request) {
        return service.retryFinanceProjection(id, request);
    }
}
