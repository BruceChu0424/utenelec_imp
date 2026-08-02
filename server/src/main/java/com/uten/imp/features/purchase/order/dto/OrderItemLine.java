package com.uten.imp.features.purchase.order.dto;

import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

@Getter
@Setter
public class OrderItemLine {
    private Integer lineNo;
    @NotNull private UUID goodsId;
    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;
    @NotNull private BigDecimal qty;
    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private BigDecimal giftQty;
    /** 关联申请明细（新建/编辑必填；审核时回写 ordered_qty）。 */
    @NotNull private UUID requestItemId;
    private LocalDate deliverDate;
    private BigDecimal weight;
    private String sourceDocNo;
    private String remark;
}
