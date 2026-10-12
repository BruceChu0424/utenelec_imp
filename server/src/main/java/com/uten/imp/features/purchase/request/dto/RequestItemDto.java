package com.uten.imp.features.purchase.request.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

@Getter
public class RequestItemDto {
    @lombok.Setter private String quantitySemantics = "LEGACY_RECORDED";
    @lombok.Setter private BigDecimal giftOrderedQty = BigDecimal.ZERO;
    @lombok.Setter private BigDecimal remainingGiftQty = BigDecimal.ZERO;
    @lombok.Setter private BigDecimal pendingGiftQty = BigDecimal.ZERO;
    @lombok.Setter private BigDecimal physicalRemainingQty = BigDecimal.ZERO;

    public RequestItemDto(UUID id, Integer lineNo, UUID goodsId, String goodsCodeSnapshot, String goodsNameSnapshot, String goodsSnapshotSource, OffsetDateTime goodsSnapshotLockedAt, UUID colorId, UUID unitId, BigDecimal unitRate, BigDecimal qty, BigDecimal price, BigDecimal amountOriginal, BigDecimal amountLocal, BigDecimal orderedQty, BigDecimal giftQty, BigDecimal weight, String sourceDocNo, LocalDate deliverDate, String productionPlanNo, String salesOrderNo, String remark, BigDecimal pendingQty, BigDecimal remainingQty, long rowVersion) {
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
        this.orderedQty = orderedQty;
        this.giftQty = giftQty;
        this.weight = weight;
        this.sourceDocNo = sourceDocNo;
        this.deliverDate = deliverDate;
        this.productionPlanNo = productionPlanNo;
        this.salesOrderNo = salesOrderNo;
        this.remark = remark;
        this.pendingQty = pendingQty;
        this.remainingQty = remainingQty;
        this.physicalRemainingQty = remainingQty;
        this.rowVersion = rowVersion;
    }
    public String getGiftQtyExact(){return com.uten.imp.common.util.DecimalText.of(giftQty);}
    public String getUnitRateExact(){return com.uten.imp.common.util.DecimalText.of(unitRate);}
    public String getPhysicalQtyExact(){return com.uten.imp.common.finance.ProcurementQuantities.physicalText(quantitySemantics,qty,giftQty);}
    public String getGiftOrderedQtyExact(){return com.uten.imp.common.util.DecimalText.of(giftOrderedQty);}
    public String getPendingGiftQtyExact(){return com.uten.imp.common.util.DecimalText.of(pendingGiftQty);}
    public BigDecimal getPhysicalOrderedQty(){return (orderedQty==null?BigDecimal.ZERO:orderedQty).add(giftOrderedQty==null?BigDecimal.ZERO:giftOrderedQty);}
    public BigDecimal getPhysicalPendingQty(){return (pendingQty==null?BigDecimal.ZERO:pendingQty).add(pendingGiftQty==null?BigDecimal.ZERO:pendingGiftQty);}
    public String getPhysicalOrderedQtyExact(){return com.uten.imp.common.util.DecimalText.of(getPhysicalOrderedQty());}
    public String getPhysicalPendingQtyExact(){return com.uten.imp.common.util.DecimalText.of(getPhysicalPendingQty());}
    public String getPhysicalRemainingQtyExact(){return com.uten.imp.common.util.DecimalText.of(physicalRemainingQty);}
    public String getRemainingGiftQtyExact(){return com.uten.imp.common.util.DecimalText.of(remainingGiftQty);}

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
    private BigDecimal orderedQty;
    private BigDecimal giftQty;
    private BigDecimal weight;
    private String sourceDocNo;
    private LocalDate deliverDate;
    private String productionPlanNo;
    private String salesOrderNo;
    private String remark;
    private BigDecimal pendingQty;
    private BigDecimal remainingQty;
    private long rowVersion;

    /** Existing internal readers remain source-compatible; live ORM rows supply the persistent version. */
    public RequestItemDto(UUID id, Integer lineNo, UUID goodsId, String goodsCodeSnapshot,
            String goodsNameSnapshot, String goodsSnapshotSource, OffsetDateTime goodsSnapshotLockedAt,
            UUID colorId, UUID unitId, BigDecimal unitRate, BigDecimal qty, BigDecimal price,
            BigDecimal amountOriginal, BigDecimal amountLocal, BigDecimal orderedQty, BigDecimal giftQty,
            BigDecimal weight, String sourceDocNo, LocalDate deliverDate, String productionPlanNo,
            String salesOrderNo, String remark, BigDecimal pendingQty, BigDecimal remainingQty) {
        this(id, lineNo, goodsId, goodsCodeSnapshot, goodsNameSnapshot, goodsSnapshotSource,
                goodsSnapshotLockedAt, colorId, unitId, unitRate, qty, price, amountOriginal, amountLocal,
                orderedQty, giftQty, weight, sourceDocNo, deliverDate, productionPlanNo, salesOrderNo,
                remark, pendingQty, remainingQty, 0);
    }
    public String getQtyExact(){return com.uten.imp.common.util.DecimalText.of(qty);}
    public String getOrderedQtyExact(){return com.uten.imp.common.util.DecimalText.of(orderedQty);}
    public String getPendingQtyExact(){return com.uten.imp.common.util.DecimalText.of(pendingQty);}
    public String getRemainingQtyExact(){return com.uten.imp.common.util.DecimalText.of(remainingQty);}
}
