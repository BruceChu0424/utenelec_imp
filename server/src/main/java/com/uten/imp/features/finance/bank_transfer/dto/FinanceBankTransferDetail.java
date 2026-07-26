package com.uten.imp.features.finance.bank_transfer.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 银行存取款单详情。 */
@Getter
@AllArgsConstructor
public class FinanceBankTransferDetail {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private UUID outAccountId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private String invoiceNo;
    private UUID operatorId;
    private UUID makerId;
    private UUID approverId;
    private String remark;
    private Short status;
    private boolean closed;
    private List<FinanceBankTransferLineDto> items;
}
