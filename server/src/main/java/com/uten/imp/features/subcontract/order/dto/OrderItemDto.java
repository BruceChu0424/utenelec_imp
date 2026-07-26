package com.uten.imp.features.subcontract.order.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 委外订货明细返回 DTO。含 4 个累计量（received/returned/issued/material_returned_qty，
 * 由下游单据审核回写）+ applicationItemId。
 */
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
