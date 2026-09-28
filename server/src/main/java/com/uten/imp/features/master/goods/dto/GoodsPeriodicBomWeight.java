package com.uten.imp.features.master.goods.dto;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 产品 BOM 里一条期间边 (组件整批领到车间内料仓, ADR-131 §3.2) 的单个重量, 货品详情只读展示。
 *
 * @param qty             单个重量 (组件基本单位)
 * @param unitWeightGrams 单个重量 (克); 组件基本单位不能按克换算时为 null, 按 qty + unitName 显示
 */
public record GoodsPeriodicBomWeight(UUID bomItemId, UUID materialGoodsId, String materialCode,
                                     String materialName, UUID colorId, String colorName,
                                     BigDecimal qty, String unitName, BigDecimal unitWeightGrams) {
}
