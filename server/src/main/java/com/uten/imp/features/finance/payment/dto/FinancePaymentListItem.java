package com.uten.imp.features.finance.payment.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 采购付款单列表行。 */
@Getter
@AllArgsConstructor
public class FinancePaymentListItem {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID supplierId;
    private UUID accountId;
    private BigDecimal amountLocal;
    private Short status;
    private Integer legacyId;
}
