package com.uten.imp.features.stock.weight.dto;

import java.util.List;

/**
 * POST /api/stock/weight/params 响应体 (ADR-135 §7.2, ADR-151 修订)。
 *
 * @param items         单重参数, 与请求 lines 同序一一对应; 每项带 (goodsId, supplierId) 身份
 * @param stockBalances 库存均重参考, 按 (warehouseId, goodsId, colorId) 去重, 只含请求里带仓库且有正数重量余额的组合;
 *                      与单重分开返回 —— 单重是学习事实, 库存均重是账面快照, 两者不互相替代
 */
public record WeightParamsResponse(List<WeightParams> items, List<StockWeightBalance> stockBalances) {
}
