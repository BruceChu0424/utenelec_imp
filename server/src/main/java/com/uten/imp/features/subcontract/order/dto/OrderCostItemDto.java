package com.uten.imp.features.subcontract.order.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 委外订货 BOM 成本子表返回 DTO（只读）。design doc 22 §五：本期不自动展开，
 * 仅展示迁老库的 67 行原样数据 + waste_allowance 字段化余量。
 *
 * <p>前端按 {@code bomLevel} 与 {@code parentCostItemId} 自关联渲染树状结构。
 */
@Getter
@AllArgsConstructor
public class OrderCostItemDto {
    private UUID id;
    private Integer bomLevel;
    private UUID parentCostItemId;
    private UUID orderItemId;
    private UUID parentGoodsId;
    private UUID parentColorId;
    private UUID goodsId;
    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;
    private BigDecimal unitQty;
    private BigDecimal qty;
    private BigDecimal wasteAllowance;
    private BigDecimal issuedQty;
    private BigDecimal returnedQty;
    private String lineClass;
    private String sourceDocNo;
    private String remark;
}
