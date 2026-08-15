package com.uten.imp.features.subcontract.material_issue.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 委外发料明细返回 DTO。含子件维度的 returned_qty/wasted_qty 累计量 + parent_goods_id 父件反查。
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
    private UUID orderItemId;
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
}
