package com.uten.imp.features.finance.bank_transfer.dto;

import com.uten.imp.common.finance.ServerDerivedAmounts;
import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 银行存取款单新建/编辑请求。 */
@Getter
@Setter
public class FinanceBankTransferSaveRequest implements ServerDerivedAmounts {

    private String billNo;

    @NotNull
    private LocalDate billDate;

    private UUID outAccountId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private String invoiceNo;
    private UUID operatorId;
    private String remark;

    @Valid
    @Size(max = RequestLimits.DOCUMENT_LINES)
    private List<FinanceBankTransferLineInput> items;
}
