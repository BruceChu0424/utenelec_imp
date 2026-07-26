package com.uten.imp.features.finance.bank_transfer.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 银行存取款明细返回 DTO。 */
@Getter
@AllArgsConstructor
public class FinanceBankTransferLineDto {
    private UUID id;
    private Integer lineNo;
    private UUID inAccountId;
    private LocalDate occurDate;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private String summary;
}
