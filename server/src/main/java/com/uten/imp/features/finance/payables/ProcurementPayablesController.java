package com.uten.imp.features.finance.payables;

import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.UUID;

import static com.uten.imp.features.finance.payables.ProcurementPayablesContracts.*;

/** Purchase/subcontract payable workbench; all monetary calculations are server-side. */
@RestController
@RequestMapping("/api/finance/payables")
@RequiredArgsConstructor
public class ProcurementPayablesController {
    private final ProcurementPayablesService service;

    @GetMapping
    @PreAuthorize("hasAuthority('ar_ap_ledger:view') and hasAuthority('finance:view:all')")
    public Page list(
            @RequestParam(required = false) String businessType,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) UUID settlementMethodId,
            @RequestParam(required = false)
            @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false)
            @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false)
            @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dueFrom,
            @RequestParam(required = false)
            @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dueTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "30") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(businessType, supplierId, status, settlementMethodId,
                dateFrom, dateTo, dueFrom, dueTo, keyword, page, size, sort, order);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('ar_ap_ledger:view') and hasAuthority('finance:view:all')")
    public Detail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping("/payment-preview")
    @PreAuthorize("hasAuthority('ar_ap_ledger:view') and hasAuthority('finance:view:all') and hasAuthority('finance_payment:create')")
    public PaymentPreview paymentPreview(@RequestBody PaymentPreviewRequest request) {
        return service.paymentPreview(request);
    }
}
