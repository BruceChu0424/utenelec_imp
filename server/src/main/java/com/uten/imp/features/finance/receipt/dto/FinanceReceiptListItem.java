package com.uten.imp.features.finance.receipt.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 销售收款单列表行。 */
@Getter
@AllArgsConstructor
public class FinanceReceiptListItem {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private String receiptKind;
    private UUID salesOrderId;
    private UUID clientId;
    private UUID accountId;
    private BigDecimal amountLocal;
    private Short status;
    private Integer legacyId;

    // Additive exact text never passes through a binary floating-point value.
    public String getAmountLocalExact() { return com.uten.imp.common.util.DecimalText.of(amountLocal); }
}
