package com.uten.imp.features.finance.expense.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/** 一般费用明细返回 DTO。 */
@Getter
@AllArgsConstructor
public class FinanceExpenseItemDto {
    private UUID id;
    private Integer lineNo;
    private UUID expenseStyleId;        // 费用项目（payment_styles EXPENSE）
    private UUID departmentId;          // 分摊部门
    private UUID counterpartAccountId;
    private String counterpartName;
    private BigDecimal qty;
    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private String summary;
    private String remark;
}
