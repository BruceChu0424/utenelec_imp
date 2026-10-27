package com.uten.imp.features.purchase.receipt.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/** 收货明细返回 DTO。 */
@Getter

public class ReceiptItemDto extends com.uten.imp.common.finance.ProcurementSourceOrderDifferenceResponse {
    @lombok.Setter private String giftReplacementIntent;
    @lombok.Setter private String quantitySemantics = "LEGACY_RECORDED";
    @lombok.Setter private BigDecimal giftReturnedQty = BigDecimal.ZERO;
    @lombok.Setter private BigDecimal returnableGiftQty = BigDecimal.ZERO;
    @lombok.Setter private BigDecimal giftStockedQty = BigDecimal.ZERO;

    public ReceiptItemDto(UUID id, Integer lineNo, UUID goodsId, String goodsCodeSnapshot, String goodsNameSnapshot, String goodsSnapshotSource, OffsetDateTime goodsSnapshotLockedAt, UUID colorId, UUID unitId, BigDecimal unitRate, BigDecimal qty, BigDecimal price, BigDecimal amountOriginal, BigDecimal amountLocal, BigDecimal returnedQty, BigDecimal giftQty, BigDecimal weight, UUID orderItemId, UUID orderId, String orderBillNo, String sourceDocNo, String remark) {
        this.id = id;
        this.lineNo = lineNo;
        this.goodsId = goodsId;
        this.goodsCodeSnapshot = goodsCodeSnapshot;
        this.goodsNameSnapshot = goodsNameSnapshot;
        this.goodsSnapshotSource = goodsSnapshotSource;
        this.goodsSnapshotLockedAt = goodsSnapshotLockedAt;
        this.colorId = colorId;
        this.unitId = unitId;
        this.unitRate = unitRate;
        this.qty = qty;
        this.price = price;
        this.amountOriginal = amountOriginal;
        this.amountLocal = amountLocal;
        this.returnedQty = returnedQty;
        this.giftQty = giftQty;
        this.weight = weight;
        this.orderItemId = orderItemId;
        this.orderId = orderId;
        this.orderBillNo = orderBillNo;
        this.sourceDocNo = sourceDocNo;
        this.remark = remark;
    }
    public String getGiftQtyExact(){return com.uten.imp.common.util.DecimalText.of(giftQty);}
    public String getPhysicalQtyExact(){return com.uten.imp.common.finance.ProcurementQuantities.physicalText(quantitySemantics,qty,giftQty);}
    public String getGiftReturnedQtyExact(){return com.uten.imp.common.util.DecimalText.of(giftReturnedQty);}
    public String getReturnableGiftQtyExact(){return com.uten.imp.common.util.DecimalText.of(returnableGiftQty);}
    public String getGiftStockedQtyExact(){return com.uten.imp.common.util.DecimalText.of(giftStockedQty);}

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
    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private BigDecimal returnedQty;
    private BigDecimal giftQty;
    private BigDecimal weight;
    private UUID orderItemId;
    /** 来源订货单 id（明细级，供点击跳详情）；无订货关联时为 null。 */
    private UUID orderId;
    /** 来源订货单编号（明细级展示：编号而非 id）；无订货关联时为 null。 */
    private String orderBillNo;
    private String sourceDocNo;
    private String remark;

    // Exact text preserves recorded decimals and explicit unknown values.
    public String getQtyExact() { return com.uten.imp.common.util.DecimalText.of(qty); }
    public String getPriceExact() { return com.uten.imp.common.util.DecimalText.of(price); }
    public String getUnitRateExact() { return com.uten.imp.common.util.DecimalText.of(unitRate); }
    public String getAmountOriginalExact() { return com.uten.imp.common.util.DecimalText.of(amountOriginal); }
    public String getAmountLocalExact() { return com.uten.imp.common.util.DecimalText.of(amountLocal); }
    public String getReturnedQtyExact(){return com.uten.imp.common.util.DecimalText.of(returnedQty);}
}
