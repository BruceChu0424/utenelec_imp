package com.uten.imp.features.sales.quote.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/** 销售报价明细返回 DTO。 */
@Getter
@AllArgsConstructor
public class QuoteItemDto {
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
    private BigDecimal weight;
    private String remark;
}
