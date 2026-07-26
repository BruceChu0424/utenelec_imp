package com.uten.imp.features.subcontract.ret.dto;

import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/** 委外退货单保存请求中的明细行（create/update 嵌套）。 */
@Getter
@Setter
public class ReturnItemLine {

    private Integer lineNo;

    @NotNull
    private UUID goodsId;

    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;

    @NotNull
    private BigDecimal qty;

    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;

    /** 关联进仓明细（可选；审核回写 receipt_items.returned_qty）。 */
    private UUID receiptItemId;

    /** 关联订货明细（可选；审核回写 order_items.returned_qty）。 */
    private UUID orderItemId;

    private BigDecimal weight;

    private String sourceDocNo;
    private String remark;
}
