package com.uten.imp.features.stock.weight;

import java.math.BigDecimal;

/**
 * 调用方带进库存账的一笔重量证据(千克)。只有两种来历: 仓库实称(MEASURED)或来源单据实称的累计切片(SLICE);
 * 均重/估算/精确换算/红冲镜像都由库存账自己推算, 调用方不传。
 *
 * <p>红冲一律传 null: 库存账按同一来源行的原流水镜像回去(ADR-135 §2.3 POOL)。
 */
public record CapturedWeight(BigDecimal kg, WeightSource source) {

    public CapturedWeight {
        if (kg == null) {
            throw new IllegalArgumentException("captured weight requires kg");
        }
        if (source != WeightSource.MEASURED && source != WeightSource.SLICE) {
            throw new IllegalArgumentException("captured weight source must be MEASURED or SLICE");
        }
        if (kg.signum() < 0) {
            throw new IllegalArgumentException("inventory movement weight must not be negative");
        }
        kg = WeightMath.normalizeInput(kg);
    }

    /** 仓库实称; 没称(空或 0)返回 null, 由库存账按均重/单重推算。 */
    public static CapturedWeight measured(BigDecimal kg) {
        return kg == null || kg.signum() <= 0 ? null : new CapturedWeight(kg, WeightSource.MEASURED);
    }

    /** 来源单据实称的累计切片; 切片可以是 0(见 §2.3 第 7 条), 空表示来源没有重量。 */
    public static CapturedWeight slice(BigDecimal kg) {
        return kg == null ? null : new CapturedWeight(kg, WeightSource.SLICE);
    }
}
