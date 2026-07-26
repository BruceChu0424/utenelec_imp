package com.uten.imp.features.subcontract.waste.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/** 委外损耗明细返回 DTO。含 ending/standard/waste_rate/cause + material_issue_item_id 真FK。 */
@Getter
@AllArgsConstructor
public class WasteItemDto {
    private UUID id;
    private Integer lineNo;
    private UUID goodsId;
    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;
    private BigDecimal qty;
    private BigDecimal endingQty;
    private BigDecimal standardQty;
    private BigDecimal wasteRate;
    private String cause;
    private UUID materialIssueItemId;
    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private BigDecimal weight;
    private String sourceDocNo;
    private String remark;
}
