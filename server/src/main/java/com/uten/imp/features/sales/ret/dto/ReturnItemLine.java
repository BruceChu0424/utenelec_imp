package com.uten.imp.features.sales.ret.dto;

import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/** 销售退货保存请求中的明细行。 */
@Getter
@Setter
public class ReturnItemLine {

    private Integer lineNo;

    /** 关联出货明细（可选；有则审核回写 sales_shipment_items.returned_qty/amount）。 */
    private UUID outItemId;

    /** 关联订货明细（可选；有则审核回写 sales_order_items.returned_qty + 订货结案重算）。 */
    private UUID orderItemId;

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
    private BigDecimal costAmount;
    private BigDecimal weight;
    private String clientNo;
    private String clientModel;
    private String solution;
    private String responsible;
    /** Discount 折扣。 */
    private BigDecimal discount;
    private String sourceDocNo;
    private String remark;
}
