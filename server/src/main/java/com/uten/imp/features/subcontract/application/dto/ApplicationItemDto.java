package com.uten.imp.features.subcontract.application.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/** 委外申请明细返回 DTO（含已订量 ordered_qty，订货审核回写）。 */
@Getter
@AllArgsConstructor
public class ApplicationItemDto {
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
    private BigDecimal orderedQty;
    private BigDecimal weight;
    private String sourceDocNo;
    private String remark;
}
