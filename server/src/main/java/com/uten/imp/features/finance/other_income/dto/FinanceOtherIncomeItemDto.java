package com.uten.imp.features.finance.other_income.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/** 其它收入明细返回 DTO。 */
@Getter
@AllArgsConstructor
public class FinanceOtherIncomeItemDto {
    private UUID id;
    private Integer lineNo;
    private UUID incomeStyleId;          // 收入项目（payment_styles INCOME）
    private UUID departmentId;
    private UUID counterpartAccountId;
    private String counterpartName;
    private BigDecimal qty;
    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private String summary;
    private String remark;

    // Additive exact text never passes through a binary floating-point value.
    public String getQtyExact() { return com.uten.imp.common.util.DecimalText.of(qty); }
    public String getPriceExact() { return com.uten.imp.common.util.DecimalText.of(price); }
    public String getAmountOriginalExact() { return com.uten.imp.common.util.DecimalText.of(amountOriginal); }
    public String getAmountLocalExact() { return com.uten.imp.common.util.DecimalText.of(amountLocal); }
}
