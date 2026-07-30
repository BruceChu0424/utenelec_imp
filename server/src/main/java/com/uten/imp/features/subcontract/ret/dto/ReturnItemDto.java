package com.uten.imp.features.subcontract.ret.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/** 委外退货明细返回 DTO。 */
@Getter
@AllArgsConstructor
public class ReturnItemDto {
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
    private UUID receiptItemId;
    private UUID orderItemId;
    private BigDecimal weight;
    private String sourceDocNo;
    private String remark;

    private BigDecimal girthQty;
    private Integer stepLegacyId;
    private String receiptNo;
    private String orderNo;
}
