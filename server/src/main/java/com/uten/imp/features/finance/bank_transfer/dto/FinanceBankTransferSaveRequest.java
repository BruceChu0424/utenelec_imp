package com.uten.imp.features.finance.bank_transfer.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 银行存取款单新建/编辑请求。 */
@Getter
@Setter
public class FinanceBankTransferSaveRequest {

    private String billNo;

    @NotNull
    private LocalDate billDate;

    private UUID outAccountId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private String invoiceNo;
    private UUID operatorId;
    private String remark;

    @Valid
    private List<FinanceBankTransferLineInput> items;
}
