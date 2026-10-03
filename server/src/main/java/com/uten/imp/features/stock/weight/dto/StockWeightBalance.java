package com.uten.imp.features.stock.weight.dto;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 同一实物仓库、货品、颜色的正数库存重量快照。数量是基本单位, 重量是 kg。
 * 用于界面按本次数量比例预填, 不是实称证据; 正式过账仍在库存锁下重读余额。
 * 库存账没有供应商/归属/批次重量子账, 因此不能把本快照标成某供应商或来源批次的实称重量。
 */
public record StockWeightBalance(UUID warehouseId, UUID colorId, BigDecimal qtyBase,
                                 BigDecimal weightKg, boolean estimated) {
}
