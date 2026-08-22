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

import static com.uten.imp.features.finance.payables.SupplierSettlementContracts.*;

/** Frozen supplier monthly statement workflow. */
@RestController
@RequestMapping("/api/finance/supplier-settlements")
@RequiredArgsConstructor
public class SupplierSettlementController {
    private final SupplierSettlementService service;

    @GetMapping
    @PreAuthorize("hasAuthority('supplier_settlement:view')")
    public BatchPage list(
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false)
            @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate periodStart,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "30") int size) {
        return service.list(supplierId, periodStart, status, keyword, page, size);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('supplier_settlement:view')")
    public BatchDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('supplier_settlement:create')")
    public BatchDetail freeze(@RequestBody FreezeRequest request) {
        return service.freeze(request);
    }

    @PostMapping("/{id}/supplier-confirm")
    @PreAuthorize("hasAuthority('supplier_settlement:confirm')")
    public BatchDetail supplierConfirm(@PathVariable UUID id, @RequestBody ConfirmRequest request) {
        return service.supplierConfirm(id, request);
    }

    @PostMapping("/{id}/internal-confirm")
    @PreAuthorize("hasAuthority('supplier_settlement:confirm')")
    public BatchDetail internalConfirm(@PathVariable UUID id, @RequestBody ConfirmRequest request) {
        return service.internalConfirm(id, request);
    }

    @PostMapping("/{id}/dispute")
    @PreAuthorize("hasAuthority('supplier_settlement:dispute')")
    public BatchDetail dispute(@PathVariable UUID id, @RequestBody DisputeRequest request) {
        return service.dispute(id, request);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('supplier_settlement:reverse')")
    public BatchDetail reverse(@PathVariable UUID id, @RequestBody ReverseRequest request) {
        return service.reverse(id, request);
    }
}
