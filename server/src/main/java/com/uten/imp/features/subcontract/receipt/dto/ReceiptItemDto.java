package com.uten.imp.features.subcontract.receipt.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/** 委外进仓明细返回 DTO。 */
@Getter
@AllArgsConstructor
public class ReceiptItemDto {
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
    private BigDecimal checkQty;
    private BigDecimal orderQty;
    private BigDecimal returnedQty;
    private BigDecimal weight;
    private UUID orderItemId;
    private String sourceDocNo;
    private String remark;

    private BigDecimal girthQty;
    private Integer stepLegacyId;
    private BigDecimal returnAmount;
    private String returnNo;
    private String orderNo;
}
