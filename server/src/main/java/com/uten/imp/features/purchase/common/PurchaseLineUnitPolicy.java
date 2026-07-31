package com.uten.imp.features.purchase.common;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/**
 * Normalizes and validates the quantity unit used by purchase document lines.
 *
 * <p>The current master data has a goods base unit but no authoritative
 * goods/unit conversion table. Consequently, a missing unit can only be
 * defaulted safely to the goods base unit with a rate of {@code 1}; an explicit
 * non-base unit must carry its own positive conversion rate.</p>
 */
@Service
@RequiredArgsConstructor
public class PurchaseLineUnitPolicy {

    private static final BigDecimal MIN_STORABLE_RATE = new BigDecimal("0.000001");

    private final EntityManager em;

    public ResolvedUnit normalizeAndValidate(
            UUID goodsId,
            UUID unitId,
            BigDecimal unitRate,
            int lineNo) {
        if (goodsId == null) {
            throw validation(lineNo, "缺少货品");
        }

        List<Object[]> goodsRows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT g.is_deleted, u.id, COALESCE(u.is_deleted, TRUE)
                                FROM goods g
                                LEFT JOIN units u ON u.legacy_id = g.unit_legacy_id
                                WHERE g.id = :goodsId
                                """)
                        .setParameter("goodsId", goodsId));
        if (goodsRows.size() != 1
                || Boolean.TRUE.equals(goodsRows.getFirst()[0])
                || goodsRows.getFirst()[1] == null
                || Boolean.TRUE.equals(goodsRows.getFirst()[2])) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    prefix(lineNo) + "货品不存在、已删除或未维护有效基本单位");
        }

        UUID baseUnitId = (UUID) goodsRows.getFirst()[1];
        if (unitId == null) {
            if (unitRate != null && unitRate.compareTo(BigDecimal.ONE) != 0) {
                throw validation(lineNo, "单位缺失且换算率不为 1，无法判定采购单位");
            }
            return new ResolvedUnit(baseUnitId, BigDecimal.ONE);
        }

        if (Objects.equals(unitId, baseUnitId)) {
            BigDecimal normalizedRate = unitRate == null ? BigDecimal.ONE : unitRate;
            if (normalizedRate.compareTo(BigDecimal.ONE) != 0) {
                throw validation(lineNo, "使用货品基本单位时换算率必须为 1");
            }
            return new ResolvedUnit(unitId, normalizedRate);
        }

        Number activeUnitCount = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM units
                        WHERE id = :unitId
                          AND is_deleted = FALSE
                        """)
                .setParameter("unitId", unitId)
                .getSingleResult();
        if (activeUnitCount.longValue() != 1L) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    prefix(lineNo) + "单位不存在或已删除");
        }
        if (unitRate == null) {
            throw validation(lineNo, "使用非基本单位时必须提供单位换算率");
        }
        BigDecimal canonicalRate = unitRate.stripTrailingZeros();
        int integerDigits = Math.max(0, canonicalRate.precision() - canonicalRate.scale());
        if (unitRate.compareTo(MIN_STORABLE_RATE) < 0
                || canonicalRate.scale() > 6
                || integerDigits > 12) {
            throw validation(lineNo, "单位换算率必须可存储为大于 0 的 NUMERIC(18,6)");
        }
        return new ResolvedUnit(unitId, unitRate);
    }

    private static ApiException validation(int lineNo, String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, prefix(lineNo) + message);
    }

    private static String prefix(int lineNo) {
        return "第 " + lineNo + " 行";
    }

    public record ResolvedUnit(UUID unitId, BigDecimal unitRate) {
    }
}
