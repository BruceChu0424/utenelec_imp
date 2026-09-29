package com.uten.imp.features.stock.weight;

import java.time.Instant;
import java.util.Objects;
import java.util.UUID;

/**
 * 估算器输入: 一条有效 (ACTIVE 且未排除) 的称重观测。
 *
 * @param id         观测 id (排序的次级键, 按 PostgreSQL uuid 顺序)
 * @param kind       来源种类
 * @param qtyBase    基本单位数量 (&gt; 0)
 * @param weightKg   净重 kg (&gt; 0)
 * @param observedAt 称重时间
 * @param supplierId 供应商 (只对 REFERENCE 有意义; CHECK 一律按 null 处理)
 * @param qtyEps     本条数量相对误差覆盖值, null 用来源默认
 */
public record WeightObservation(
        UUID id,
        SourceKind kind,
        double qtyBase,
        double weightKg,
        Instant observedAt,
        UUID supplierId,
        Double qtyEps) {

    public WeightObservation {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(kind, "kind");
        Objects.requireNonNull(observedAt, "observedAt");
        if (!(qtyBase > 0) || !(weightKg > 0) || !Double.isFinite(qtyBase) || !Double.isFinite(weightKg)) {
            throw new IllegalArgumentException("observation qty and weight must be positive");
        }
        if (qtyEps != null && !(qtyEps >= 0 && Double.isFinite(qtyEps))) {
            throw new IllegalArgumentException("qtyEps must be >= 0");
        }
    }

    /** 本条使用的数量相对误差。 */
    public double eps() {
        return qtyEps != null ? qtyEps : kind.eps();
    }
}
