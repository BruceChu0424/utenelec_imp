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

    /** 关联来源订货明细；不把子件数量回写到成品行累计字段。 */
    private UUID orderItemId;

    /** 来源发料计划行（V304）；仓库拣货保存时随草稿行回传。 */
    private UUID planItemId;

    private UUID parentGoodsId;
    private UUID parentColorId;
    private BigDecimal weight;

    private String sourceDocNo;
    private String remark;

    private BigDecimal boxQty;
    private String returnNo;
    private String orderNo;
}
