package com.uten.imp.features.stock.ledger;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * 流水查询条件 (已校验、仓库已展开成范围)。
 *
 * <p>范围条件 (仓库含下级、颜色) 同时决定结存锚点与参与倒推的行; 显示条件 (类型、方向、截止日期、
 * 是否显示重量调整) 只在倒推之后筛行, 不改变结存。起始日期可以安全地裁掉更早的行 (倒推只用更新的行)。
 *
 * @param goodsId                  货品
 * @param warehouseScope           仓库范围 (null = 全部仓库)
 * @param colorId                  颜色 (与 colorNull 互斥, 优先)
 * @param colorNull                只看无颜色
 * @param from                     起始时刻 (含; null = 不限)
 * @param toExclusive              截止时刻 (不含; null = 不限)
 * @param types                    出入库类型筛选 (空 = 不限)
 * @param adjustmentsRequested     类型筛选里点名了重量调整 (伪类型 W)
 * @param direction                方向筛选 +1/-1 (null = 不限; 给了就不显示重量调整行)
 * @param includeWeightAdjustments 未按类型筛选时是否显示重量调整行
 * @param limit                    每页行数
 * @param offset                   跳过行数
 */
record StockLedgerQuery(
        UUID goodsId,
        Set<UUID> warehouseScope,
        UUID colorId,
        boolean colorNull,
        OffsetDateTime from,
        OffsetDateTime toExclusive,
        List<Short> types,
        boolean adjustmentsRequested,
        Short direction,
        boolean includeWeightAdjustments,
        int limit,
        long offset) {

    StockLedgerQuery {
        types = types == null ? List.of() : List.copyOf(types);
    }

    /** 显示出入库行 (M): 没有类型筛选, 或类型筛选里有具体类型。 */
    boolean showsMovements() {
        return !typeFiltered() || !types.isEmpty();
    }

    /** 显示重量调整行 (W): 有类型筛选时看是否点名 W, 否则看开关; 按方向筛选时不显示。 */
    boolean showsAdjustments() {
        boolean wanted = typeFiltered() ? adjustmentsRequested : includeWeightAdjustments;
        return wanted && direction == null;
    }

    boolean typeFiltered() {
        return !types.isEmpty() || adjustmentsRequested;
    }
}
