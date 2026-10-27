package com.uten.imp.features.purchase.ret.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

@Getter
public class ReturnItemDto extends com.uten.imp.common.finance.ProcurementSourceOrderDifferenceResponse {
    @lombok.Setter private String quantitySemantics = "LEGACY_RECORDED";
    @lombok.Setter private BigDecimal giftQty = BigDecimal.ZERO;

    public ReturnItemDto(UUID id, Integer lineNo, UUID goodsId, String goodsCodeSnapshot, String goodsNameSnapshot, String goodsSnapshotSource, OffsetDateTime goodsSnapshotLockedAt, UUID colorId, UUID unitId, BigDecimal unitRate, BigDecimal qty, BigDecimal price, BigDecimal amountOriginal, BigDecimal amountLocal, UUID receiptItemId, UUID orderItemId, BigDecimal weight, String sourceDocNo, String remark) {
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
        this.receiptItemId = receiptItemId;
        this.orderItemId = orderItemId;
        this.weight = weight;
        this.sourceDocNo = sourceDocNo;
        this.remark = remark;
    }
    public String getGiftQtyExact(){return com.uten.imp.common.util.DecimalText.of(giftQty);}
    public String getUnitRateExact(){return com.uten.imp.common.util.DecimalText.of(unitRate);}
    public String getPhysicalQtyExact(){return com.uten.imp.common.finance.ProcurementQuantities.physicalText(quantitySemantics,qty,giftQty);}


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
    private UUID receiptItemId;
    private UUID orderItemId;
    @Override public UUID getOrderItemId() { return orderItemId; }
    private BigDecimal weight;
    private String sourceDocNo;
    private String remark;
}
