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
}
