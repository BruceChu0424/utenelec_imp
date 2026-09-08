package com.uten.imp.features.finance.payment.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/** 采购付款核销明细返回 DTO。 */
@Getter
@AllArgsConstructor
public class FinancePaymentLineDto {
    private UUID id;
    private Integer lineNo;
    private UUID appliedLedgerId;
    private String appliedBillNo;
    private UUID supplierId;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private BigDecimal appliedAmountLocal;
    private BigDecimal exchangeDiff;
    private String remark;

    // Additive exact text never passes through a binary floating-point value.
    public String getAmountOriginalExact() { return com.uten.imp.common.util.DecimalText.of(amountOriginal); }
    public String getAmountLocalExact() { return com.uten.imp.common.util.DecimalText.of(amountLocal); }
    public String getAppliedAmountLocalExact() { return com.uten.imp.common.util.DecimalText.of(appliedAmountLocal); }
    public String getExchangeDiffExact() { return com.uten.imp.common.util.DecimalText.of(exchangeDiff); }
}
