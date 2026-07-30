package com.uten.imp.features.finance.receipt.dto;

import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/** 销售收款单保存请求中的明细行（create/update 嵌套）。 */
@Getter
@Setter
public class FinanceReceiptLineInput {

    private Integer lineNo;

    /** 核销的 AR 行 id（为 null 表示直接收款未指定核销；非空时审核回写 amount_settled）。 */
    private UUID appliedLedgerId;

    private String appliedBillNo;

    private UUID clientId;

    @NotNull
    private BigDecimal amountOriginal;

    @NotNull
    private BigDecimal amountLocal;

    private BigDecimal exchangeDiff;

    private String remark;
}
