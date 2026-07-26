package com.uten.imp.features.subcontract.waste.dto;

import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 委外损耗单保存请求中的明细行。含特有 ending_qty/standard_qty/waste_rate/cause。
 */
@Getter
@Setter
public class WasteItemLine {

    private Integer lineNo;

    @NotNull
    private UUID goodsId;

    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;

    @NotNull
    private BigDecimal qty;

    private BigDecimal endingQty;
    private BigDecimal standardQty;
    private BigDecimal wasteRate;
    private String cause;

    /** 关联发料明细（可选；审核回写 material_issue_items.wasted_qty，★新库补全）。 */
    private UUID materialIssueItemId;

    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private BigDecimal weight;

    private String sourceDocNo;
    private String remark;
}
