package com.uten.imp.features.finance.payment.dto;

import com.uten.imp.common.finance.ServerDerivedAmounts;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/** 采购付款单保存请求中的明细行。 */
@Getter
@Setter
public class FinancePaymentLineInput implements ServerDerivedAmounts {

    private Integer lineNo;
    private UUID appliedLedgerId;
    /** Compatibility-only display value; the service copies the bill number from the AP ledger. */
    private String appliedBillNo;
    /** Optional consistency check; the persisted supplier always comes from the AP ledger. */
    private UUID supplierId;

    @NotNull
    @DecimalMin(value = "0", inclusive = false)
    private BigDecimal amountOriginal;

    private String remark;
}
