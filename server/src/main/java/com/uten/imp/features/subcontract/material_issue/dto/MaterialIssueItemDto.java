package com.uten.imp.features.subcontract.material_issue.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 委外发料明细返回 DTO。含子件维度的供应商处子账（V221 守恒台账）：
 * atSupplierQty 已发至供应商 / consumedQty 回厂已消费 / returnedQty 已材料退 /
 * wastedQty 已损耗 / supplierEnding 供应商期末结存（派生 = 发出−消费−退−损耗，
 * 与 DB 生成列同口径），以及 frozenUnitQty 冻结 BOM 单耗快照 + parent_goods_id 父件反查。
 */
@Getter
@AllArgsConstructor
public class MaterialIssueItemDto {
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
    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private BigDecimal returnedQty;
    private BigDecimal wastedQty;
    private BigDecimal atSupplierQty;
    private BigDecimal consumedQty;
    private BigDecimal frozenUnitQty;
    private UUID orderItemId;
    /** 来源发料计划行（V304）；计划生成的出仓单必填。 */
    private UUID planItemId;
    private UUID parentGoodsId;
    private String parentGoodsCodeSnapshot;
    private String parentGoodsNameSnapshot;
    private String parentGoodsSnapshotSource;
    private OffsetDateTime parentGoodsSnapshotLockedAt;
    private UUID parentColorId;
    private BigDecimal weight;
    private String sourceDocNo;
    private String remark;

    private BigDecimal boxQty;
    private String returnNo;
    private String orderNo;

    /** 供应商期末结存 = 发出 − 已消费 − 已退 − 已损耗（派生展示口径，不落库）。 */
    public BigDecimal getSupplierEnding() {
        BigDecimal at = atSupplierQty == null ? BigDecimal.ZERO : atSupplierQty;
        return at
                .subtract(consumedQty == null ? BigDecimal.ZERO : consumedQty)
                .subtract(returnedQty == null ? BigDecimal.ZERO : returnedQty)
                .subtract(wastedQty == null ? BigDecimal.ZERO : wastedQty);
    }
}
