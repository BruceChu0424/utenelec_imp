package com.uten.imp.features.sales.ret.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/** 销售退货明细返回 DTO。 */
@Getter
@AllArgsConstructor
public class ReturnItemDto {
    private UUID id;
    private Integer lineNo;
    /** OutID → sales_shipment_items.id（可空）。 */
    private UUID outItemId;
    /** OrderID → sales_order_items.id（双挂，可空）。 */
    private UUID orderItemId;
    private UUID goodsId;
    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;
    private BigDecimal qty;
    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private BigDecimal costAmount;
    private BigDecimal weight;
    private String clientNo;
    private String clientModel;
    /** qlfa 处理方案（退货专属）。 */
    private String solution;
    /** zrdw 责任单位（退货专属）。 */
    private String responsible;
    private BigDecimal discount;
    private String sourceDocNo;
    private String remark;
}
