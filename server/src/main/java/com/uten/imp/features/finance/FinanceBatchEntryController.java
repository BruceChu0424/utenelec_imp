package com.uten.imp.features.finance;

import com.fasterxml.jackson.databind.JsonNode;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/finance")
@RequiredArgsConstructor
public class FinanceBatchEntryController {
    private final FinanceBatchEntryService service;

    public record Request(
            @NotNull @Pattern(regexp="[A-Za-z0-9._:-]{8,120}") String idempotencyKey,
            @NotEmpty @Size(max=500) List<@NotNull JsonNode> documents) {}

    @PostMapping("/receipts/batch")
    @PreAuthorize("hasAuthority('finance_receipt:create')")
    public JsonNode receipts(@Valid @RequestBody Request request) { return service.create("receipts", request); }

    @PostMapping("/payments/batch")
    @PreAuthorize("hasAuthority('finance_payment:create')")
    public JsonNode payments(@Valid @RequestBody Request request) { return service.create("payments", request); }

    @PostMapping("/expenses/batch")
    @PreAuthorize("hasAuthority('finance_expense:create')")
    public JsonNode expenses(@Valid @RequestBody Request request) { return service.create("expenses", request); }

    @PostMapping("/incomes/batch")
    @PreAuthorize("hasAuthority('finance_other_income:create')")
    public JsonNode incomes(@Valid @RequestBody Request request) { return service.create("incomes", request); }

    @PostMapping("/bank-transfers/batch")
    @PreAuthorize("hasAuthority('finance_bank_transfer:create')")
    public JsonNode transfers(@Valid @RequestBody Request request) { return service.create("bank-transfers", request); }
}
