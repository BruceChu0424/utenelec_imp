package com.uten.imp.features.subcontract.material_return.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/** 委外材料退明细返回 DTO。 */
@Getter
@AllArgsConstructor
public class MaterialReturnItemDto {
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
    private UUID materialIssueItemId;
    private UUID orderItemId;
    private UUID parentGoodsId;
    private UUID parentColorId;
    private BigDecimal weight;
    private String sourceDocNo;
    private String remark;
}
