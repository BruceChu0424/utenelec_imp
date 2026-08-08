package com.uten.imp.features.finance.receipt.dto;

import jakarta.validation.constraints.DecimalMin;
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

    /** 引用的 AR 行 id；普通销售收款审核时必填。 */
    private UUID appliedLedgerId;

    private String appliedBillNo;

    private UUID clientId;

    private UUID currencyId;

    @DecimalMin(value = "0", inclusive = false)
    private BigDecimal exchangeRate;

    @NotNull
    @DecimalMin(value = "0", inclusive = false)
    private BigDecimal amountOriginal;

    /** 服务端按 amountOriginal × exchangeRate 权威重算；字段仅为旧客户端兼容，可不传。 */
    private BigDecimal amountLocal;

    /** 服务端按到账汇率与开账汇率权威重算；客户端值不会入账。 */
    private BigDecimal exchangeDiff;

    @DecimalMin(value = "0")
    private BigDecimal writeOffAmount;

    private String remark;
}
