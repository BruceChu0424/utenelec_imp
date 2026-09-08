package com.uten.imp.features.finance.receipt.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/** 销售收款核销明细返回 DTO。 */
@Getter
@AllArgsConstructor
public class FinanceReceiptLineDto {
    private UUID id;
    private Integer lineNo;
    private UUID appliedLedgerId;     // 核销的 AR 行（为 null 表示直接收款未指定核销）
    private String appliedBillNo;     // 老库 SellID 立帐单号
    private UUID clientId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private BigDecimal writeOffAmount;
    private BigDecimal writeOffLocal;
    private BigDecimal appliedAmountLocal;
    private BigDecimal balanceBeforeOriginal;
    private BigDecimal balanceAfterOriginal;
    private BigDecimal exchangeDiff;
    private String remark;

    // Additive exact text never passes through a binary floating-point value.
    public String getExchangeRateExact() { return com.uten.imp.common.util.DecimalText.of(exchangeRate); }
    public String getAmountOriginalExact() { return com.uten.imp.common.util.DecimalText.of(amountOriginal); }
    public String getAmountLocalExact() { return com.uten.imp.common.util.DecimalText.of(amountLocal); }
    public String getWriteOffAmountExact() { return com.uten.imp.common.util.DecimalText.of(writeOffAmount); }
    public String getWriteOffLocalExact() { return com.uten.imp.common.util.DecimalText.of(writeOffLocal); }
    public String getAppliedAmountLocalExact() { return com.uten.imp.common.util.DecimalText.of(appliedAmountLocal); }
    public String getBalanceBeforeOriginalExact() { return com.uten.imp.common.util.DecimalText.of(balanceBeforeOriginal); }
    public String getBalanceAfterOriginalExact() { return com.uten.imp.common.util.DecimalText.of(balanceAfterOriginal); }
    public String getExchangeDiffExact() { return com.uten.imp.common.util.DecimalText.of(exchangeDiff); }
}
