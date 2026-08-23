package com.uten.imp.features.finance.receivables;

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

import static com.uten.imp.features.finance.receivables.CustomerPrepaymentContracts.*;

/** Finance-only customer advance workbench and reversible application API. */
@RestController
@RequiredArgsConstructor
public class CustomerPrepaymentController {
    private final CustomerPrepaymentQueryService query;
    private final CustomerPrepaymentOffsetService offsets;

    @GetMapping("/api/finance/customer-prepayments")
    @PreAuthorize("hasAuthority('customer_prepayment:view') and hasAuthority('finance:view:all')")
    public PrepaymentPage list(
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) UUID currencyId,
            @RequestParam(required = false) UUID salesOrderId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return query.list(clientId, currencyId, salesOrderId, page, size);
    }

    @GetMapping("/api/finance/customer-prepayments/sales-orders/{salesOrderId}/summary")
    @PreAuthorize("hasAuthority('customer_prepayment:view') and hasAuthority('finance:view:all')")
    public SalesOrderMoneySummary salesOrderSummary(@PathVariable UUID salesOrderId) {
        return query.salesOrderSummary(salesOrderId);
    }

    @PostMapping("/api/finance/customer-prepayment-offsets")
    @PreAuthorize("hasAuthority('customer_prepayment:view') and hasAuthority('customer_prepayment:apply') "
            + "and hasAuthority('finance:view:all')")
    public BatchDetail apply(@Valid @RequestBody ApplyRequest request) {
        return offsets.apply(request);
    }

    @PostMapping("/api/finance/customer-prepayment-offsets/{batchId}/reverse")
    @PreAuthorize("hasAuthority('customer_prepayment:view') and hasAuthority('customer_prepayment:reverse') "
            + "and hasAuthority('finance:view:all')")
    public BatchDetail reverse(
            @PathVariable UUID batchId,
            @Valid @RequestBody ReverseRequest request) {
        return offsets.reverse(batchId, request);
    }

    @GetMapping("/api/finance/customer-prepayment-offsets/{batchId}")
    @PreAuthorize("hasAuthority('customer_prepayment:view') and hasAuthority('finance:view:all')")
    public BatchDetail detail(@PathVariable UUID batchId) {
        return offsets.detail(batchId);
    }
}
