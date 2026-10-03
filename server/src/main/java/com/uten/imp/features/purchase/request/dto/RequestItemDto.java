package com.uten.imp.features.purchase.request.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

@Getter @AllArgsConstructor
public class RequestItemDto {
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
}
