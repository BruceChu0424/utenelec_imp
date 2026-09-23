package com.uten.imp.features.finance.receipt.dto;

import com.uten.imp.common.finance.ServerDerivedAmounts;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/** 销售收款单保存请求中的明细行（create/update 嵌套）。 */
@Getter
@Setter
public class FinanceReceiptLineInput implements ServerDerivedAmounts {

    private Integer lineNo;

    /** 引用的 AR 行 id；普通销售收款审核时必填。 */
    private UUID appliedLedgerId;

    private String appliedBillNo;

    private UUID clientId;

    /** 应收/核销原币；必须与被引用 AR 一致，不代表收款账户币种。 */
    private UUID currencyId;

    /** 当前批次实际到账汇率，必须逐行填写，不得覆盖其它批次或回退开账汇率。 */
    @NotNull
    @DecimalMin(value = "0", inclusive = false)
    private BigDecimal exchangeRate;

    @NotNull
    @DecimalMin(value = "0", inclusive = false)
    private BigDecimal amountOriginal;


    @DecimalMin(value = "0")
    private BigDecimal writeOffAmount;

    private String remark;
}
