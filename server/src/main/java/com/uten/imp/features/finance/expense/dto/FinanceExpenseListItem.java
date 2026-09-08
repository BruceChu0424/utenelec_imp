package com.uten.imp.features.finance.expense.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 一般费用单列表行。 */
@Getter
@AllArgsConstructor
public class FinanceExpenseListItem {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID accountId;
    private BigDecimal amountLocal;
    private Short status;
    private Integer legacyId;

    // Additive exact text never passes through a binary floating-point value.
    public String getAmountLocalExact() { return com.uten.imp.common.util.DecimalText.of(amountLocal); }
}
