package com.uten.imp.features.subcontract.waste.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/** 委外损耗明细返回 DTO。含 ending/standard/waste_rate/cause + material_issue_item_id 真FK。 */
@Getter
@AllArgsConstructor
public class WasteItemDto {
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
    public String getWeightExact(){return com.uten.imp.common.util.DecimalText.of(weight);}
    public String getUnitRateExact(){return com.uten.imp.common.util.DecimalText.of(unitRate);}
    public String getQtyExact(){return com.uten.imp.common.util.DecimalText.of(qty);}
    public String getEndingQtyExact(){return com.uten.imp.common.util.DecimalText.of(endingQty);}
    public String getStandardQtyExact(){return com.uten.imp.common.util.DecimalText.of(standardQty);}
    public String getWasteRateExact(){return com.uten.imp.common.util.DecimalText.of(wasteRate);}
    public String getPriceExact(){return com.uten.imp.common.util.DecimalText.of(price);}
    public String getAmountOriginalExact(){return com.uten.imp.common.util.DecimalText.of(amountOriginal);}
    public String getAmountLocalExact(){return com.uten.imp.common.util.DecimalText.of(amountLocal);}
}
