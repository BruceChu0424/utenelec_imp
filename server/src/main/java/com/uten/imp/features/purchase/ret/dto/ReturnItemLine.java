package com.uten.imp.features.purchase.ret.dto;

import com.uten.imp.common.finance.ServerDerivedAmounts;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

@Getter @Setter
public class ReturnItemLine implements ServerDerivedAmounts {
    private Integer lineNo;
    @NotNull private UUID goodsId;
    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;
    @NotNull private BigDecimal qty;
    private BigDecimal price;
    /** 关联收货明细（有则回写 receipt_items.returned_qty）。 */
    private UUID receiptItemId;
    /** 关联订货明细（有则回写 order_items.returned_qty + 结案重算）。 */
    private UUID orderItemId;
    private BigDecimal weight;
    private String sourceDocNo;
    private String remark;
}
