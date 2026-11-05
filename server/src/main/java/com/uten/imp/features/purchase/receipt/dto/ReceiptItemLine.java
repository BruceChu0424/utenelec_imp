package com.uten.imp.features.purchase.receipt.dto;

import com.uten.imp.common.validation.DocumentQuantity;
import com.uten.imp.common.finance.ServerDerivedAmounts;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 收货单保存请求中的明细行（create/update 嵌套）。
 */
@Getter
@Setter
public class ReceiptItemLine extends com.uten.imp.common.platformcolumns.PlatformColumnLineInput implements ServerDerivedAmounts {

    /** Optional original row locator; the server still proves parent and all quantity/source operands. */
    @com.fasterxml.jackson.annotation.JsonInclude(com.fasterxml.jackson.annotation.JsonInclude.Include.NON_NULL)
    private UUID id;
    private Integer lineNo;
    /** Retained row identity required only by the dedicated review amendment. */
    private UUID sourceItemId;

    @NotNull
    private UUID goodsId;

    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;

    @NotNull
    @DocumentQuantity
    private BigDecimal qty;

    @jakarta.validation.constraints.Pattern(regexp = "NORMAL|RETURN_REPLACEMENT")
    private String replacementIntent;
    @jakarta.validation.constraints.Pattern(regexp="NORMAL|RETURN_REPLACEMENT")
    private String giftReplacementIntent;

    private BigDecimal price;
    @jakarta.validation.constraints.DecimalMin("0")
    @DocumentQuantity
    private BigDecimal giftQty;

    /** 关联订货明细（可选；有则审核时回写 received_qty）。 */
    private UUID orderItemId;

    private BigDecimal weight;
    private String sourceDocNo;
    private String remark;
}
