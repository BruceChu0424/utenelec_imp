package com.uten.imp.features.subcontract.order.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 委外订货明细返回 DTO。received/returned 是成品维度权威累计；
 * issued/materialReturned 为兼容旧客户端保留的 legacy 展示值，新业务不写。
 * 另含 applicationItemId。
 */
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
    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private BigDecimal receivedQty;
    private BigDecimal returnedQty;
    private BigDecimal issuedQty;
    private BigDecimal materialReturnedQty;
    private UUID applicationItemId;
    private LocalDate deliverDate;
    private BigDecimal weight;
    private String sourceDocNo;
    private String remark;
}
