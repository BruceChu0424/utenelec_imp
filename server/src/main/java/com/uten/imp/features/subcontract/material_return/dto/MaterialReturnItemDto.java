package com.uten.imp.features.subcontract.material_return.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/** 委外材料退明细返回 DTO。 */
@Getter
@AllArgsConstructor
public class MaterialReturnItemDto {
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
    private UUID materialIssueItemId;
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

    private BigDecimal girthQty;
    private String issueNo;
    private String orderNo;
}
