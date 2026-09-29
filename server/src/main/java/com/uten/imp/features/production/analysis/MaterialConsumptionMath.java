package com.uten.imp.features.production.analysis;

import java.math.BigDecimal;
import java.math.RoundingMode;

/**
 * Exact BOM consumption arithmetic: the single Java formula shared by material
 * analysis, execution complete-kit allocation
 * ({@code CompleteKitAllocator.ConsumptionRule}) and the plan-import BOM view.
 * SQL has two twins of it, both proven equal by
 * {@code MaterialConsumptionMathSqlContractPostgresTest} (ADR-129 §2.3):
 * <ul>
 *   <li>{@code fn_material_analysis_edge_required} (V247): one BOM edge; MRP
 *       and the plan-import need subtotals.</li>
 *   <li>{@code fn_material_snapshot_required} (V609): the per-rule sum over a
 *       demand's frozen {@code consumption_snapshot}; the demand-insert guard
 *       and the split, growth and reservation assertions. Java evaluates the
 *       same curve with {@code CompleteKitAllocator.required(rules, qty, rate)}.</li>
 * </ul>
 */
public final class MaterialConsumptionMath {

    public static final String PER_UNIT = "PER_UNIT";
    public static final String PER_PACKAGE = "PER_PACKAGE";
    public static final String FIXED_BATCH = "FIXED_BATCH";

    /**
     * 用量不大于零的 BOM 行给人看的原因与修法，各读者共用。新写入已被
     * goods_bom_qty_positive_chk 拦住，但 V182 加约束时用 NOT VALID 放过了存量，
     * 所以读者把这种行标成问题，不交给本类计算(本类对它直接拒绝)。
     */
    public static final String NON_POSITIVE_BOM_QTY_REASON = "用量小于或等于 0";
    public static final String NON_POSITIVE_BOM_QTY_FIX = "请在父件的 BOM 里把这一行的用量改成大于 0";

    private MaterialConsumptionMath() {
    }

    public static BigDecimal required(
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

    public static BigDecimal effectivePerProduct(
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
