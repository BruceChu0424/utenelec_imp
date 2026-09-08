package com.uten.imp.features.purchase.receipt.dto;

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
public class ReceiptItemLine {

    private Integer lineNo;

    @NotNull
    private UUID goodsId;

    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;

    @NotNull
    private BigDecimal qty;

    @jakarta.validation.constraints.Pattern(regexp = "NORMAL|RETURN_REPLACEMENT")
    private String replacementIntent;

    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private BigDecimal giftQty;

    /** 关联订货明细（可选；有则审核时回写 received_qty）。 */
    private UUID orderItemId;

    private BigDecimal weight;
    private String sourceDocNo;
    private String remark;
}
