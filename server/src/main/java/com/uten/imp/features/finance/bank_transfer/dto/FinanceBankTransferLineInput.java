package com.uten.imp.features.finance.bank_transfer.dto;

import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 银行存取款单保存请求中的明细行。 */
@Getter
@Setter
public class FinanceBankTransferLineInput {

    private Integer lineNo;
    private UUID inAccountId;
    private LocalDate occurDate;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private String summary;
}
