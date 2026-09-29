package com.uten.imp.features.sales.order.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

/** 销售订货明细返回 DTO。 */
@Getter
@AllArgsConstructor
public class OrderItemDto {
    private UUID id;
    private Integer lineNo;
    private UUID goodsId;
    private String goodsCodeSnapshot;
    private String goodsNameSnapshot;
    private String goodsSnapshotSource;
    private OffsetDateTime goodsSnapshotLockedAt;
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
    /** 订单行优先级（销售链路用）：1急单/2普通/3现货(默认)。 */
    @Setter
    private Short priority;
    /** ADR-134 客户文件上的品名/描述原文。 */
    @Setter
    private String clientGoodsName;
    /** ADR-134 客户文件上的单价原文(不脱敏: 是客户自己的资料)。 */
    @Setter
    private BigDecimal clientPrice;
    /** 来源报价行由财务核定的折扣(报价转入的订单才有; 脱敏时置空)。 */
    @Setter
    private BigDecimal quoteDiscount;
    /** 本行单价/折扣由来源报价锁定(折扣只读, 显示「报价核定」)。 */
    @Setter
    private boolean quoteLocked;

    // Exact text is derived after permission masking; null stays null.
    public String getUnitRateExact() { return com.uten.imp.common.util.DecimalText.of(unitRate); }
    public String getQtyExact() { return com.uten.imp.common.util.DecimalText.of(qty); }
    public String getPriceExact() { return com.uten.imp.common.util.DecimalText.of(price); }
    public String getAmountOriginalExact() { return com.uten.imp.common.util.DecimalText.of(amountOriginal); }
    public String getAmountLocalExact() { return com.uten.imp.common.util.DecimalText.of(amountLocal); }
    public String getShippedQtyExact() { return com.uten.imp.common.util.DecimalText.of(shippedQty); }
    public String getReturnedQtyExact() { return com.uten.imp.common.util.DecimalText.of(returnedQty); }
    public String getFlagQtyExact() { return com.uten.imp.common.util.DecimalText.of(flagQty); }
    public String getDiscountExact() { return com.uten.imp.common.util.DecimalText.of(discount); }
    public String getTaxAmountExact() { return com.uten.imp.common.util.DecimalText.of(taxAmount); }
    public String getWeightExact() { return com.uten.imp.common.util.DecimalText.of(weight); }
    public String getMachiningPriceExact() { return com.uten.imp.common.util.DecimalText.of(machiningPrice); }
    public String getCircumferenceExact() { return com.uten.imp.common.util.DecimalText.of(circumference); }
    public String getInboundQtyExact() { return com.uten.imp.common.util.DecimalText.of(inboundQty); }
    public String getReservedQtyExact() { return com.uten.imp.common.util.DecimalText.of(reservedQty); }
    public String getPlannedQtyExact() { return com.uten.imp.common.util.DecimalText.of(plannedQty); }
    public String getProducedQtyExact() { return com.uten.imp.common.util.DecimalText.of(producedQty); }
    public String getQuotePriceExact() { return com.uten.imp.common.util.DecimalText.of(quotePrice); }
    public String getQuoteDiscountExact() { return com.uten.imp.common.util.DecimalText.of(quoteDiscount); }
    public String getClientPriceExact() { return com.uten.imp.common.util.DecimalText.of(clientPrice); }
}
