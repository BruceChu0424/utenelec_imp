package com.uten.imp.features.subcontract.material_issue.dto;

import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 委外材料出仓单保存请求中的明细行。<b>无 Price</b>（材料按成本发出，amount 可空）。
 */
@Getter
@Setter
public class MaterialIssueItemLine {

    private Integer lineNo;

    @NotNull
    private UUID goodsId;

    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;

    @NotNull
    private BigDecimal qty;

    /** 无 Price；空。 */
    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;

    /** 关联订货明细（可选；审核回写 issued_qty）。 */
    private UUID orderItemId;

    private UUID parentGoodsId;
    private UUID parentColorId;
    private BigDecimal weight;

    private String sourceDocNo;
    private String remark;
}
