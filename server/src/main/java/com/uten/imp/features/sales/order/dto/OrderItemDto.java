package com.uten.imp.features.sales.order.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 销售订货明细返回 DTO。 */
@Getter
@AllArgsConstructor
public class OrderItemDto {
    private UUID id;
    private Integer lineNo;
    private UUID goodsId;
    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;
    private BigDecimal qty;
    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private BigDecimal shippedQty;
    private BigDecimal returnedQty;
    private BigDecimal flagQty;
    private BigDecimal discount;
    private BigDecimal taxAmount;
    private BigDecimal weight;
    private String clientNo;
    private String clientModel;
    private LocalDate deliverDate;
    private String sourceDocNo;
    private String remark;
}
