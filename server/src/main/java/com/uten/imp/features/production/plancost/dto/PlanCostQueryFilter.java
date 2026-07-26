package com.uten.imp.features.production.plancost.dto;

import java.time.LocalDate;
import java.util.UUID;

/**
 * BOM 展开查询过滤（design §6.2）。
 *
 * @param planItemId       计划明细 id（最频繁：按计划明细展开子树，对应 idx_ppc_billitem）
 * @param masterGoodsId    顶层成品（按成品汇总，对应 idx_ppc_mgoods）
 * @param goodsId          节点货品（按物料需求，对应 idx_ppc_goods）
 * @param parentId         BOM 子树遍历（对应 idx_ppc_parent）
 * @param supplierId       建议供应方
 * @param salesOrderCostItemId 销售成本溯源（对应 idx_ppc_socitem）
 * @param dateFrom         bill_date 起（分区裁剪 + idx_ppc_date）
 * @param dateTo           bill_date 止
 */
public record PlanCostQueryFilter(
        UUID planItemId,
        UUID masterGoodsId,
        UUID goodsId,
        UUID parentId,
        UUID supplierId,
        UUID salesOrderCostItemId,
        LocalDate dateFrom,
        LocalDate dateTo) {
}
