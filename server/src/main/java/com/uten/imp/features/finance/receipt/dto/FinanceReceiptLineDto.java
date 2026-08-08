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
}
