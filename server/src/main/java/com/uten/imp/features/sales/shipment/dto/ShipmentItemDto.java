package com.uten.imp.features.sales.shipment.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/** 销售出货明细返回 DTO。 */
@Getter
@AllArgsConstructor
public class ShipmentItemDto {
    private UUID id;
    private Integer lineNo;
    private UUID orderItemId;
    private UUID goodsId;
    private String goodsCodeSnapshot;
    private String goodsNameSnapshot;
    private String goodsSnapshotSource;
    private OffsetDateTime goodsSnapshotLockedAt;
    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;
    private BigDecimal qty;
    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private BigDecimal costAmount;
    private BigDecimal returnedQty;
    private BigDecimal returnedAmount;
    private BigDecimal weight;
    private BigDecimal parcelQty;
    private BigDecimal cartonCount;
    private String clientNo;
    private String clientModel;
    private BigDecimal materialPrice;
    private BigDecimal dieCastPrice;
    private BigDecimal machiningPrice;
    private BigDecimal circumference;
    private BigDecimal discount;
    private String sourceDocNo;
    private String remark;

    // Exact text is derived after permission masking; null stays null.
    public String getUnitRateExact() { return com.uten.imp.common.util.DecimalText.of(unitRate); }
    public String getQtyExact() { return com.uten.imp.common.util.DecimalText.of(qty); }
    public String getPriceExact() { return com.uten.imp.common.util.DecimalText.of(price); }
    public String getAmountOriginalExact() { return com.uten.imp.common.util.DecimalText.of(amountOriginal); }
    public String getAmountLocalExact() { return com.uten.imp.common.util.DecimalText.of(amountLocal); }
    public String getCostAmountExact() { return com.uten.imp.common.util.DecimalText.of(costAmount); }
    public String getReturnedQtyExact() { return com.uten.imp.common.util.DecimalText.of(returnedQty); }
    public String getReturnedAmountExact() { return com.uten.imp.common.util.DecimalText.of(returnedAmount); }
    public String getWeightExact() { return com.uten.imp.common.util.DecimalText.of(weight); }
    public String getParcelQtyExact() { return com.uten.imp.common.util.DecimalText.of(parcelQty); }
    public String getCartonCountExact() { return com.uten.imp.common.util.DecimalText.of(cartonCount); }
    public String getMaterialPriceExact() { return com.uten.imp.common.util.DecimalText.of(materialPrice); }
    public String getDieCastPriceExact() { return com.uten.imp.common.util.DecimalText.of(dieCastPrice); }
    public String getMachiningPriceExact() { return com.uten.imp.common.util.DecimalText.of(machiningPrice); }
    public String getCircumferenceExact() { return com.uten.imp.common.util.DecimalText.of(circumference); }
    public String getDiscountExact() { return com.uten.imp.common.util.DecimalText.of(discount); }
}
