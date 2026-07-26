package com.uten.imp.features.finance.other_income.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 其它收入单详情。 */
@Getter
@AllArgsConstructor
public class FinanceOtherIncomeDetail {
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
    private UUID receiptMethodId;
    private Integer receiptMethodLegacyId;
    private UUID operatorId;
    private UUID makerId;
    private UUID approverId;
    private String remark;
    private Short status;
    private boolean closed;
    private List<FinanceOtherIncomeItemDto> items;
}
