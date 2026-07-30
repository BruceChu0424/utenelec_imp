package com.uten.imp.features.finance.other_income.dto;

import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/** 其它收入单保存请求中的明细行。 */
@Getter
@Setter
public class FinanceOtherIncomeItemInput {

    private Integer lineNo;
    private UUID incomeStyleId;
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
