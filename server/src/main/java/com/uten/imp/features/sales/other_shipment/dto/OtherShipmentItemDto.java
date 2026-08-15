package com.uten.imp.features.sales.other_shipment.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/** 其它出货明细返回 DTO。 */
@Getter
@AllArgsConstructor
public class OtherShipmentItemDto {
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
    private BigDecimal returnedQty;
    private BigDecimal returnedAmount;
    private String sourceDocNo;
    private String remark;
}
