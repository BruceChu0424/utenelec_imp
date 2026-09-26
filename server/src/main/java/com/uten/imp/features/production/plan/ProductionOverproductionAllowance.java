package com.uten.imp.features.production.plan;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.math.BigDecimal;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import jakarta.persistence.EntityManager;
import com.uten.imp.common.util.NativeQueryResults;

/** One numeric contract for manual plans, analysis issuance and their read-only previews. */
public final class ProductionOverproductionAllowance {
    public static final BigDecimal DEFAULT_RATE = new BigDecimal("0.10");

    private ProductionOverproductionAllowance() {}

    /** Null is an omitted intention; explicit zero must never select a default. */
    public static BigDecimal resolve(EntityManager em, UUID goodsId, BigDecimal rate) {
        if (rate != null) return normalize(rate);
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

    public static BigDecimal normalize(BigDecimal rate) {
        if (rate == null) return DEFAULT_RATE;
        BigDecimal normalized = rate.stripTrailingZeros();
        if (normalized.signum() < 0 || normalized.compareTo(new BigDecimal("1000")) >= 0
                || normalized.scale() > 6) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "允许超产比例应为非负数，比例小数最多保留六位且小于1000");
        }
        return normalized;
    }
}
