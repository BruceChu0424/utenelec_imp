package com.uten.imp.features.finance.other_income.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 其它收入单列表行。 */
@Getter
@AllArgsConstructor
public class FinanceOtherIncomeListItem {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID accountId;
    private BigDecimal amountLocal;
    private Short status;
    private Integer legacyId;
}
