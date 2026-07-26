package com.uten.imp.features.production.plancost.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * BOM 展开列表行（只读 · 前端解析货品/颜色/供应商名称）。
 *
 * <p>16 个数量族全部保留，便于前端 BOM 树形展示与未来 MRP 模块复用。
 */
@Getter
@AllArgsConstructor
public class PlanCostRow {
    private UUID id;
    private Integer legacyId;
    private UUID billItemId;
    private String billNo;
    private LocalDate billDate;
    private UUID parentId;
    private Integer parentLegacyId;
    private Short level;
    private Short nodeClass;
    private UUID goodsId;
    private UUID colorId;
    private UUID masterGoodsId;
    private UUID masterColorId;
    private UUID salesOrderCostItemId;
    // 数量族（16）
    private BigDecimal qty;
    private BigDecimal dqty;
    private BigDecimal pqty;
    private BigDecimal lqty;
    private BigDecimal slqty;
    private BigDecimal rqty;
    private BigDecimal orderQty;
    private BigDecimal inQty;
    private BigDecimal pdrawQty;
    private BigDecimal owdrawQty;
    private BigDecimal pwdrawQty;
    private BigDecimal eoQty;
    private BigDecimal eiQty;
    private BigDecimal ewQty;
    private BigDecimal mqty;
    private BigDecimal paQty;
    // 金额
    private BigDecimal price;
    private BigDecimal total;
    private UUID supplierId;
    private Integer assTeamLegacyId;
    private String sourceDocNo;
    private Short lstatus;
    private String summary;
}
