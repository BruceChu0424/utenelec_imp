package com.uten.imp.features.finance.accountbalance;

import com.uten.imp.features.finance.accountbalance.dto.AccountBalanceAdjustmentBatchRequest;
import com.uten.imp.features.finance.accountbalance.dto.AccountBalanceAdjustmentBatchResult;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/** Privileged account-balance reconciliation command endpoint. */
@RestController
@RequestMapping("/api/finance/account-balance-adjustments")
@RequiredArgsConstructor
public class AccountBalanceAdjustmentController {

    private final AccountBalanceAdjustmentService service;

    @PostMapping("/batch")
    @PreAuthorize("hasAuthority('account:view') and hasAuthority('account:balance:view') "
            + "and hasAuthority('account:balance:adjust')")
    public AccountBalanceAdjustmentBatchResult adjust(
            @Valid @RequestBody AccountBalanceAdjustmentBatchRequest request) {
        return service.adjust(request);
    }
}
