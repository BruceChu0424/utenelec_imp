package com.uten.imp.features.finance.payment.dto;

import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/** 采购付款单保存请求中的明细行。 */
@Getter
@Setter
public class FinancePaymentLineInput {

    private Integer lineNo;
    private UUID appliedLedgerId;
    private String appliedBillNo;
    private UUID supplierId;

    @NotNull
    private BigDecimal amountOriginal;

    @NotNull
    private BigDecimal amountLocal;

    private BigDecimal exchangeDiff;
    private String remark;
}
