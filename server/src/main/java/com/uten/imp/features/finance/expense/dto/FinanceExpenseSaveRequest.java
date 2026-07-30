package com.uten.imp.features.finance.expense.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 一般费用单新建/编辑请求（主表字段 + 明细分摊行）。 */
@Getter
@Setter
public class FinanceExpenseSaveRequest {

    private String billNo;

    @NotNull
    private LocalDate billDate;

    private UUID accountId;
    private UUID counterpartAccountId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private UUID operatorId;
    private String remark;

    @Valid
    @NotNull
    private List<FinanceExpenseItemInput> items;
}
