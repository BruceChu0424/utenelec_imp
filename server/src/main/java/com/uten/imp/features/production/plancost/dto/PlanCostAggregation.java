package com.uten.imp.features.production.plancost.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * BOM 展开按货品/成品汇总行（只读 · design §6.2）。
 *
 * <p>不依赖物化视图：BOM 成本上卷 MV 本期不建（归未来成本模块，design §6.1 末）。
 * 此聚合由 Service 现算（按 goods_id 或 master_goods_id GROUP BY），适用于小范围（单计划/单成品）查询。
 */
@Getter
@AllArgsConstructor
public class PlanCostAggregation {
    /** 聚合维度（masterGoodsId 优先；为空则按 goodsId）。 */
    private UUID masterGoodsId;
    private UUID goodsId;
    /** SUM(qty) 总需量。 */
    private BigDecimal qtySum;
    /** SUM(pqty) 计划数量。 */
    private BigDecimal pqtySum;
    /** SUM(total) 金额。 */
    private BigDecimal totalSum;
    /** 行数。 */
    private Long lineCnt;
}
