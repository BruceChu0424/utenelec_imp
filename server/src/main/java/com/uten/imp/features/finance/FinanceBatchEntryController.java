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
import java.util.Map;
import java.util.UUID;
import com.uten.imp.common.web.ApiError;
import org.springframework.http.ResponseEntity;

@RestController
@RequestMapping("/api/finance")
@RequiredArgsConstructor
public class FinanceBatchEntryController {
    public static final int MAX_DOCUMENTS=500;
    private final FinanceBatchEntryService service;

    public record Request(
            @NotNull @Pattern(regexp="[A-Za-z0-9._:-]{8,120}") String idempotencyKey,
            @NotEmpty @Size(max=MAX_DOCUMENTS) List<@NotNull JsonNode> documents) {}
    public record Cancellation(@NotNull UUID actorId,@NotNull JsonNode requestBody) { }

    @ExceptionHandler(FinanceBatchEntryService.CancelledBatch.class)
    public ResponseEntity<ApiError> cancelled(FinanceBatchEntryService.CancelledBatch error) {
        return ResponseEntity.status(409).body(ApiError.of(error.getCode(),error.getMessage()).withDetails(error.details()));
    }

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

    @GetMapping("/receipts/batch/operations/{key}") @PreAuthorize("hasAuthority('finance_receipt:view')")
    public Map<String,Object> receiptResult(@PathVariable String key){return service.receipt("receipts",key);}
    @PostMapping("/receipts/batch/operations/{key}/cancel") @PreAuthorize("hasAuthority('finance_receipt:view')")
    public Map<String,Object> cancelReceipt(@PathVariable String key,@Valid @RequestBody Cancellation body){return service.cancelUnwritten("receipts",key,body);}

    @GetMapping("/payments/batch/operations/{key}") @PreAuthorize("hasAuthority('finance_payment:view')")
    public Map<String,Object> paymentResult(@PathVariable String key){return service.receipt("payments",key);}
    @PostMapping("/payments/batch/operations/{key}/cancel") @PreAuthorize("hasAuthority('finance_payment:view')")
    public Map<String,Object> cancelPayment(@PathVariable String key,@Valid @RequestBody Cancellation body){return service.cancelUnwritten("payments",key,body);}

    @GetMapping("/expenses/batch/operations/{key}") @PreAuthorize("hasAuthority('finance_expense:view')")
    public Map<String,Object> expenseResult(@PathVariable String key){return service.receipt("expenses",key);}
    @PostMapping("/expenses/batch/operations/{key}/cancel") @PreAuthorize("hasAuthority('finance_expense:view')")
    public Map<String,Object> cancelExpense(@PathVariable String key,@Valid @RequestBody Cancellation body){return service.cancelUnwritten("expenses",key,body);}

    @GetMapping("/incomes/batch/operations/{key}") @PreAuthorize("hasAuthority('finance_other_income:view')")
    public Map<String,Object> incomeResult(@PathVariable String key){return service.receipt("incomes",key);}
    @PostMapping("/incomes/batch/operations/{key}/cancel") @PreAuthorize("hasAuthority('finance_other_income:view')")
    public Map<String,Object> cancelIncome(@PathVariable String key,@Valid @RequestBody Cancellation body){return service.cancelUnwritten("incomes",key,body);}

    @GetMapping("/bank-transfers/batch/operations/{key}") @PreAuthorize("hasAuthority('finance_bank_transfer:view')")
    @io.swagger.v3.oas.annotations.Operation(operationId="transferResult")
    public Map<String,Object> getTransferResult(@PathVariable String key){return service.receipt("bank-transfers",key);}
    @PostMapping("/bank-transfers/batch/operations/{key}/cancel") @PreAuthorize("hasAuthority('finance_bank_transfer:view')")
    public Map<String,Object> cancelTransfer(@PathVariable String key,@Valid @RequestBody Cancellation body){return service.cancelUnwritten("bank-transfers",key,body);}
}
