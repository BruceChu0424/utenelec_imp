package com.uten.imp.features.stock.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
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
 *   <li>库存重量 = stock_balances.weight(千克，ADR-135 仓库重量账；任一有量余额行未知则整行未知)</li>
 *   <li>库存台账金额 = stock_balances.amount_local（多仓时按货品+颜色 SUM）</li>
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
    /** 库存重量(千克，多仓=SUM)；null = 有数量的余额行里有重量未知的(前端「未称」，绝不当 0)。 */
    private BigDecimal weight;
    /** 库存数量（多仓=SUM）。 */
    private BigDecimal qty;
    /** 库存台账金额（兼容既有 API 字段名 costAmount）。 */
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
    /** 品质已放行但仓库尚未确认入库的基本单位量；不属于可用库存。 */
    private BigDecimal pendingStockInQty;
    /** 库存重量含估算(按库存均重或单重估出, 前端加「≈」)；重量未知时恒 false。 */
    private boolean weightEstimated;
    /** 库存重量未知(有数量却没有可信重量)。 */
    private boolean weightUnknown;
    /** 学到的货品级单重(千克/基本单位，goods_weight_estimates 货品级行)；没学过为 null。 */
    private BigDecimal unitWeightKg;
    /** 单重可靠度 GREEN / YELLOW / RED；没学过为 null。 */
    private String weightTier;
    /** 当前用户无 goods:cost:view 时库存台账金额已由服务端置空。 */
    private boolean costMasked;
    /** Master owning warehouse, not the warehouse scope of this stock query. */
    private UUID owningWarehouseId;
    private String owningWarehouseName;
    /** 本行数量里在不良品仓的部分(ADR-146; 只有打开「含不良品仓」或直接查不良品仓时非 0)。 */
    private BigDecimal defectiveQty;

    /** Preserve the existing constructor used by stock clients and read-side tests. */
    public InstantInventoryRow(UUID goodsId, UUID colorId, String categoryName, String model, String cNumber,
                               String name, String spec, String colorName, String unitName, String remark,
                               BigDecimal weight, BigDecimal qty, BigDecimal costAmount, BigDecimal moreQty,
                               String goodsCode, String series, String stockPlace, BigDecimal pendingQty,
                               BigDecimal pendingStockInQty, boolean weightEstimated, boolean weightUnknown,
                               BigDecimal unitWeightKg, String weightTier, boolean costMasked) {
        this(goodsId, colorId, categoryName, model, cNumber, name, spec, colorName, unitName, remark,
                weight, qty, costAmount, moreQty, goodsCode, series, stockPlace, pendingQty, pendingStockInQty,
                weightEstimated, weightUnknown, unitWeightKg, weightTier, costMasked, null, null, BigDecimal.ZERO);
    }

    /** 字段名首字母后紧跟大写, Jackson 按 getter 推名会得到 cnumber; 固定为前端读的 cNumber。 */
    @JsonProperty("cNumber")
    public String getCNumber() {
        return cNumber;
    }
}
