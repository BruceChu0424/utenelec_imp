package com.uten.imp.features.production.plan;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.math.BigDecimal;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import jakarta.persistence.EntityManager;
import com.uten.imp.common.util.NativeQueryResults;

/**
 * One numeric contract for manual plans, analysis issuance and their read-only previews.
 *
 * <p>ADR-129 §2.10: a plan line records whether a person confirmed its rate. An omitted rate is
 * filled from the goods default and marked {@link #SOURCE_DEFAULT}; only a new or changed
 * {@link #SOURCE_EXPLICIT} confirmation becomes the goods' next default ({@link #remember} for
 * inserted lines, the change-gated update trigger on {@code production_plan_items} otherwise).
 */
public final class ProductionOverproductionAllowance {
    public static final String SOURCE_DEFAULT = "DEFAULT";
    public static final String SOURCE_EXPLICIT = "EXPLICIT";

    /** A plan line's rate and whether a person confirmed it. */
    public record Allowance(BigDecimal rate, String source) {
        public boolean explicit() { return SOURCE_EXPLICIT.equals(source); }
    }

    private ProductionOverproductionAllowance() {}

    /** Null is an omitted intention (goods default); explicit zero must never select a default. */
    public static Allowance allowance(EntityManager em, UUID goodsId, BigDecimal requested) {
        return requested != null
                ? new Allowance(normalize(requested), SOURCE_EXPLICIT)
                : new Allowance(goodsDefault(em, goodsId), SOURCE_DEFAULT);
    }

    /** The rate alone, for writers that never record a person's choice (MRP sub-plans, remakes, previews). */
    public static BigDecimal resolve(EntityManager em, UUID goodsId, BigDecimal rate) {
        return allowance(em, goodsId, rate).rate();
    }

    /**
     * A newly confirmed plan-line rate becomes the goods' next default; supplement plans are excluded
     * (fn_remember_plan_line_overproduction_rate, shared with the update trigger).
     * Call it only for a new or changed confirmation: a draft re-save re-inserts its unchanged lines,
     * and re-remembering them would overwrite a newer approved rate.
     */
    public static void remember(EntityManager em, UUID planId, UUID goodsId, Allowance allowance) {
        if (!allowance.explicit()) return;
        em.createNativeQuery("""
                SELECT fn_remember_plan_line_overproduction_rate(
                    CAST(:plan AS uuid), CAST(:goods AS uuid), CAST(:rate AS numeric))
                """).setParameter("plan", planId).setParameter("goods", goodsId)
                .setParameter("rate", allowance.rate()).getResultList();
    }

    /** Remembered human choice, else the structural default (fn_goods_default_overproduction_rate). */
    private static BigDecimal goodsDefault(EntityManager em, UUID goodsId) {
        BigDecimal value = (BigDecimal) em.createNativeQuery(
                "SELECT fn_goods_default_overproduction_rate(CAST(:goods AS uuid))")
                .setParameter("goods", goodsId).getSingleResult();
        if (value == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "货品不存在或已停用，无法读取允许超产比例");
        return value;
    }

    /** One bounded-by-request lookup; never aggregate growing production history. */
    public static Map<UUID, BigDecimal> defaults(EntityManager em, Set<UUID> goodsIds) {
        if (goodsIds.isEmpty()) return Map.of();
        Map<UUID, BigDecimal> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, fn_goods_default_overproduction_rate(id)
                FROM goods WHERE id IN (:ids) AND NOT is_deleted ORDER BY id
                """).setParameter("ids", goodsIds))) {
            result.put((UUID) row[0], (BigDecimal) row[1]);
        }
        return Map.copyOf(result);
    }

    /** Validates an explicit rate. There is no implicit rate: omission is resolved by {@link #allowance}. */
    public static BigDecimal normalize(BigDecimal rate) {
        Objects.requireNonNull(rate, "an omitted rate is resolved from the goods default");
        BigDecimal normalized = rate.stripTrailingZeros();
        if (normalized.signum() < 0 || normalized.compareTo(new BigDecimal("1000")) >= 0
                || normalized.scale() > 6) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "允许超产比例应为非负数，比例小数最多保留六位且小于1000");
        }
        return normalized;
    }
}
