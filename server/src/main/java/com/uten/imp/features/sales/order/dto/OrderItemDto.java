package com.uten.imp.features.sales.order.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 销售订货明细返回 DTO。 */
@Getter
@AllArgsConstructor
public class OrderItemDto {
    private UUID id;
    private Integer lineNo;
    private UUID goodsId;
    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;
    private BigDecimal qty;
    /** 以下价格族字段在无 sales_order:price:view 时由 Service 置 null 脱敏（SOP §三8）。 */
    @Setter
    private BigDecimal price;
    @Setter
    private BigDecimal amountOriginal;
    @Setter
    private BigDecimal amountLocal;
    private BigDecimal shippedQty;
    private BigDecimal returnedQty;
    private BigDecimal flagQty;
    @Setter
    private BigDecimal discount;
    @Setter
    private BigDecimal taxAmount;
    private BigDecimal weight;
    private String clientNo;
    private String clientModel;
    private LocalDate deliverDate;
    private String sourceDocNo;
    @Setter
    private BigDecimal machiningPrice;
    private BigDecimal circumference;
    private BigDecimal inboundQty;
    private String inNo;
    private String outNo;
    private String remark;
    private BigDecimal reservedQty;
    private BigDecimal plannedQty;
    private BigDecimal producedQty;
    private Short chainStatus;
    /** 来源报价行单价（报价转入的订单详情回联填充，价格留痕比对用；非转入为 null）。 */
    @Setter
    private BigDecimal quotePrice;
}
