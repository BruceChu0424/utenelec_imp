package com.uten.imp.features.finance.payment.dto;

import jakarta.validation.constraints.DecimalMin;
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
    /** Compatibility-only display value; the service copies the bill number from the AP ledger. */
    private String appliedBillNo;
    /** Optional consistency check; the persisted supplier always comes from the AP ledger. */
    private UUID supplierId;

    @NotNull
    @DecimalMin(value = "0", inclusive = false)
    private BigDecimal amountOriginal;

    /** 服务端按本次付款汇率重算；仅保留用于兼容旧客户端。 */
    private BigDecimal amountLocal;

    /** 服务端按付款汇率与应付开账汇率重算；客户端值不会入账。 */
    private BigDecimal exchangeDiff;
    private String remark;
}
