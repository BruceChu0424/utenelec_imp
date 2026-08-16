package com.uten.imp.features.stock.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 即时库存行（对标老系统「即时库存」窗口 View_IOStockGoods）。
 *
 * <p>粒度 = 货品+颜色（仓库=全部时跨「参与核算」仓库 SUM；指定仓库时该仓单行）。
 * 口径与老库一致：
 * <ul>
 *   <li>库存数量 = StockGoods 最新年 FactQTY（迁移）+ 单据审核增量 → stock_balances.qty</li>
 *   <li>库存重量 = FactWeight + 明细 weight×unit_rate 增量 → stock_balances.weight</li>
 *   <li>成本金额 = goods.c_total × 库存数量（老库 B_Goods.CTotal × FactQTY）</li>
 *   <li>多排数量 = production_plan_items 可排余量聚合（老库 View_ProductMore）</li>
 *   <li>备注 = goods.paper（老库 B_Goods.Paper，如「外购」）</li>
 * </ul>
 * 名称（分类/颜色/单位）后端直接 JOIN 出名（本查询本就 JOIN goods，顺带解析，免前端字典二次解析）。
 */
@Getter
@AllArgsConstructor
public class InstantInventoryRow {
    private UUID goodsId;
    private UUID colorId;
    /** 所属类型（货品直接分类名）。 */
    private String categoryName;
    /** 型号（goods.model）。 */
    private String model;
    /** 客户型号（goods.c_number）。 */
    private String cNumber;
    /** 货品名称。 */
    private String name;
    /** 规格。 */
    private String spec;
    /** 颜色名。 */
    private String colorName;
    /** 基本单位名。 */
    private String unitName;
    /** 备注（goods.paper，老库 B_Goods.Paper）。 */
    private String remark;
    /** 库存重量（多仓=SUM）。 */
    private BigDecimal weight;
    /** 库存数量（多仓=SUM）。 */
    private BigDecimal qty;
    /** 成本金额 = c_total × qty。 */
    private BigDecimal costAmount;
    /** 多排数量（生产计划可排余量）。 */
    private BigDecimal moreQty;
    /** 货品编号（goods.code）。 */
    private String goodsCode;
    /** 物料系列（goods.series，如塑胶件/五金件）。 */
    private String series;
    /** 库位号（goods.stock_place，仓库摆放位置；按货品一个值）。 */
    private String stockPlace;
    /** 待检量（procurement_inspection_items 收货未放行量，基本单位；>0=货在 IQC 待检）。 */
    private BigDecimal pendingQty;
}
