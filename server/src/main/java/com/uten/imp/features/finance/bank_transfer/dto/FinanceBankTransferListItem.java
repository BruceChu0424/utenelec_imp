package com.uten.imp.features.finance.bank_transfer.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 银行存取款单列表行。 */
@Getter
@AllArgsConstructor
public class FinanceBankTransferListItem {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID outAccountId;
    private BigDecimal amountLocal;
    private Short status;
    private Integer legacyId;
}
