package com.uten.imp.features.subcontract.material_return.dto;

import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/** 委外材料退货单保存请求中的明细行。<b>无 Price</b>。 */
@Getter
@Setter
public class MaterialReturnItemLine {

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

    /** 关联发料明细（可选；审核回写 material_issue_items.returned_qty）。 */
    private UUID materialIssueItemId;

    /** 关联订货明细（可选；审核回写 order_items.material_returned_qty）。 */
    private UUID orderItemId;

    private UUID parentGoodsId;
    private UUID parentColorId;
    private BigDecimal weight;

    private String sourceDocNo;
    private String remark;
}
