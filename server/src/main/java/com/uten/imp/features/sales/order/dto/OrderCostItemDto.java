package com.uten.imp.features.sales.order.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 销售订单 BOM 展开行返回 DTO（只读）。
 *
 * <p>本期只读展示（design 20 §一·13）：父/子层级、货品、需求量、累计量。orderItemId 标识所属订货明细。
 */
@Getter
@AllArgsConstructor
public class OrderCostItemDto {
    private UUID id;
    private UUID orderItemId;
    private UUID parentId;
    private Integer level;
    private Integer classCode;
    private UUID goodsId;
    private UUID colorId;
    private UUID altGoodsId;
    private UUID altColorId;
    private UUID unitId;
    private BigDecimal qty;
    private BigDecimal orderQty;
    private BigDecimal receivedQty;
    private BigDecimal drawQty;
    private BigDecimal purgeQty;
    private BigDecimal otherDrawQty;
    private UUID supplierId;
    private Short lStatus;
    private LocalDate billDate;
    private String sourceDocNo;
    private String remark;
}
