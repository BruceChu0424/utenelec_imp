package com.uten.imp.features.production.mrp;

import java.math.BigDecimal;
import java.util.UUID;

/** MRP 预览行：按货品聚合（颜色取需求最大行参考色；净需求按货品级扣库存/在途）。 */
public record MrpRow(
        UUID goodsId, String goodsCode, String goodsName, String spec,
        UUID colorId, BigDecimal gross, BigDecimal onhand, BigDecimal openPo,
        BigDecimal net, boolean selfMade, UUID unitId) {}
