package com.uten.imp.features.finance.expense.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 一般费用单详情。 */
@Getter
@AllArgsConstructor
public class FinanceExpenseDetail {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private UUID accountId;
    private UUID counterpartAccountId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private UUID operatorId;
    private UUID makerId;
    private UUID approverId;
    private String remark;
    private Short status;
    private boolean closed;
    private List<FinanceExpenseItemDto> items;
}
