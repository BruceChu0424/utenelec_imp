package com.uten.imp.features.subcontract.material_issue.dto;

import com.uten.imp.common.finance.ServerDerivedAmounts;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
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
public class MaterialIssueItemLine implements ServerDerivedAmounts {

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

    /** 关联来源订货明细；不把子件数量回写到成品行累计字段。 */
    private UUID orderItemId;

    /** 来源发料计划行（V304）；仓库拣货保存时随草稿行回传。 */
    private UUID planItemId;

    private UUID parentGoodsId;
    private UUID parentColorId;

    /**
     * 仓库出仓时实称的本行净重(千克, 4 位小数; ADR-135 §3.8); 空或 0 = 没称。
     * 按重量计的货品/单位由服务端按数量换算, 这里填的丢弃。
     */
    @DecimalMin(value = "0", inclusive = true)
    @Digits(integer = 14, fraction = 4)
    private BigDecimal weight;

    /** 数量是按称重推算的(称重计数「按称重改数量」): 为真时本行不进单重核对观测。空 = 否。 */
    private Boolean qtyFromWeight;

    private String sourceDocNo;
    private String remark;

    private BigDecimal boxQty;
    private String returnNo;
    private String orderNo;
}
