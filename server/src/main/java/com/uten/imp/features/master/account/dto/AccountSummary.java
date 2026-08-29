package com.uten.imp.features.master.account.dto;

import java.util.List;

/** Permission-gated account overview; currency buckets remain deliberately separate. */
public record AccountSummary(
        long totalAccounts,
        long activeAccounts,
        long disabledAccounts,
        long warningAccounts,
        long negativeAccounts,
        List<AccountCurrencySummary> currencies) {
}
