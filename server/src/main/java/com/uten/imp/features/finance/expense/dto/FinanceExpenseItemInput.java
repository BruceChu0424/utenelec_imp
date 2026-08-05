package com.uten.imp.features.finance.expense.dto;

import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/** 一般费用单保存请求中的明细行。 */
@Getter
@Setter
public class FinanceExpenseItemInput {

    private Integer lineNo;

    /** 费用类别（payment_styles.category='EXPENSE'）。必填：总账借方按行科目过账，空则借贷不平衡。 */
    @NotNull
    private UUID expenseStyleId;

    private UUID departmentId;
    private UUID counterpartAccountId;
    private String counterpartName;
    private BigDecimal qty;
    private BigDecimal price;
    private BigDecimal amountOriginal;

    @NotNull
    private BigDecimal amountLocal;

    private String summary;
    private String remark;
}
