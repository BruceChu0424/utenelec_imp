package com.uten.imp.features.stock.weight;

import java.math.BigDecimal;
import java.util.Optional;
import java.util.UUID;

/**
 * 库存账估重时要用的货品级单重(每个基本单位多少千克)。
 *
 * <p>由单重学习模块实现(按 精确 > 人工设定 > 学习 > 主档单重 的顺序解析, ADR-135 §5); 库存账只经
 * ObjectProvider 取它, 没有实现时当作「没有单重」处理, 重量照样不挡数量过账。
 */
public interface UnitWeightLookup {

    /** 货品级(不分供应商)单重; 没有任何依据返回 empty。 */
    Optional<UnitWeightRef> goodsLevel(UUID goodsId);

    /**
     * @param kgPerBaseUnit 每个基本单位的千克数(大于 0)
     * @param basis         EXACT / MANUAL / LEARNED / MASTER_PRIOR
     * @param tier          GREEN / YELLOW / RED(可靠 / 可参考 / 未学准)
     */
    record UnitWeightRef(BigDecimal kgPerBaseUnit, String basis, String tier) {

        /** 可靠或可参考(GREEN / YELLOW): 入库估重优先用它, 而不是本仓均重。 */
        public boolean confident() {
            return "GREEN".equals(tier) || "YELLOW".equals(tier);
        }

        /** 单重可用(大于 0)。 */
        public boolean usable() {
            return kgPerBaseUnit != null && kgPerBaseUnit.signum() > 0;
        }
    }
}
