package com.uten.imp.features.finance.receipt.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 销售收款单新建/编辑请求（主表字段 + 明细行）。明细可为空（直接收款，无显式核销）。 */
@Getter
@Setter
public class FinanceReceiptSaveRequest {

    @NotBlank
    private String billNo;

    @NotNull
    private LocalDate billDate;

    private UUID clientId;
    private UUID accountId;
    private UUID counterpartAccountId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private BigDecimal bankFee;
    private BigDecimal otherFee;
    private UUID otherFeeStyleId;
    private UUID receiptMethodId;
    private Integer receiptMethodLegacyId;
    private String invoiceNo;
    private UUID operatorId;
    private String sourceRemark;
    private String remark;

    /** 核销明细（可空：空列表 = 直接收款 / 客户预付；非空 = 指定核销若干 AR）。 */
    @Valid
    private List<FinanceReceiptLineInput> items;
}
