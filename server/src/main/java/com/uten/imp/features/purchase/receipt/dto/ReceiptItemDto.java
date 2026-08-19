package com.uten.imp.features.purchase.receipt.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/** 收货明细返回 DTO。 */
@Getter
@AllArgsConstructor
public class ReceiptItemDto {
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
}
