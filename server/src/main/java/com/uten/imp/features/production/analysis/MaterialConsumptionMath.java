package com.uten.imp.features.production.analysis;

import java.math.BigDecimal;
import java.math.RoundingMode;

/** Exact BOM consumption arithmetic shared by analysis readiness and previews. */
final class MaterialConsumptionMath {

    static final String PER_UNIT = "PER_UNIT";
    static final String PER_PACKAGE = "PER_PACKAGE";
    static final String FIXED_BATCH = "FIXED_BATCH";

    private MaterialConsumptionMath() {
    }

    static BigDecimal required(
            BigDecimal parentOutputQty,
            BigDecimal bomQty,
            String basis,
            BigDecimal basisOutputQty,
            boolean allowPartialPackage) {
        if (parentOutputQty == null || parentOutputQty.signum() <= 0) {
            return BigDecimal.ZERO.setScale(4);
        }
        requirePositive(bomQty, "BOM 用量");
        requirePositive(basisOutputQty, "包装/批次产出数");
        String normalized = normalizeBasis(basis);
        BigDecimal raw;
        if (PER_UNIT.equals(normalized)) {
            raw = parentOutputQty.multiply(bomQty);
        } else if (PER_PACKAGE.equals(normalized) && allowPartialPackage) {
            raw = parentOutputQty.multiply(bomQty)
                    .divide(basisOutputQty, 12, RoundingMode.CEILING);
        } else {
            BigDecimal packageCount = parentOutputQty.divide(
                    basisOutputQty, 0, RoundingMode.CEILING);
            raw = packageCount.multiply(bomQty);
        }
        return raw.setScale(4, RoundingMode.CEILING);
    }

    static BigDecimal effectivePerProduct(
            BigDecimal parentPerProductQty,
            BigDecimal bomQty,
            String basis,
            BigDecimal basisOutputQty) {
        requirePositive(parentPerProductQty, "父件单位耗用");
        requirePositive(bomQty, "BOM 用量");
        requirePositive(basisOutputQty, "包装/批次产出数");
        String normalized = normalizeBasis(basis);
        BigDecimal divisor = PER_UNIT.equals(normalized)
                ? BigDecimal.ONE : basisOutputQty;
        return parentPerProductQty.multiply(bomQty)
                .divide(divisor, 6, RoundingMode.CEILING);
    }

    private static String normalizeBasis(String basis) {
        String value = basis == null ? PER_UNIT : basis.strip().toUpperCase();
        if (!PER_UNIT.equals(value)
                && !PER_PACKAGE.equals(value)
                && !FIXED_BATCH.equals(value)) {
            throw new IllegalArgumentException("不支持的物料计量方式");
        }
        return value;
    }

    private static void requirePositive(BigDecimal value, String label) {
        if (value == null || value.signum() <= 0) {
            throw new IllegalArgumentException(label + "必须大于零");
        }
    }
}
