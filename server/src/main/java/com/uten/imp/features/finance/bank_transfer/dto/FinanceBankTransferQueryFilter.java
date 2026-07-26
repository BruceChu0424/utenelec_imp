package com.uten.imp.features.finance.bank_transfer.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 银行存取款单查询条件。 */
public record FinanceBankTransferQueryFilter(
        String keyword,
        UUID outAccountId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo) {
}
