package com.uten.imp.features.stock.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 仓库单据明细返回 DTO（统一）。 */
@Getter
@AllArgsConstructor
public class StockDocItemDto {
    private UUID id;
    private Integer lineNo;
    private UUID goodsId;
    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;
    private BigDecimal qty;
    private BigDecimal baseQty;
    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private BigDecimal weight;
    private BigDecimal giftQty;
    private BigDecimal surplusQty;
    private BigDecimal countQty;
    private String place;
    private UUID upstreamItemId;
    private String sourceDocNo;
    private String remark;
    private LocalDate billDate;
}
