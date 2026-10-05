package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.math.BigDecimal;
import java.math.RoundingMode;

/**
 * 采购允许超收量的唯一口径(ADR-144)。与数据库 {@code fn_purchase_over_receipt_tolerance} 同式:
 * T(q, p) = ROUND(q × COALESCE(p,0) / 100, 4), 订货单位, 四舍五入(数量列存储口径
 * {@link MoneyPolicy#quantity})。只用于采购; 委外订货没有超收比例。
 *
 * <p>T 是可选余量, 不是欠交量: 各层只在既有容量项上加 T(当前订货量, p), 不改写各层既有的
 * 退货/质检口径; T 永远不写进 arrival_overage_posted_qty 或预计到货 ordered_qty。
 */
public final class PurchaseOverReceiptTolerance {
    private static final BigDecimal HUNDRED = BigDecimal.valueOf(100);
    private static final BigDecimal QUANTITY_STEP = BigDecimal.ONE.movePointLeft(MoneyPolicy.QUANTITY_SCALE);

    private PurchaseOverReceiptTolerance() {
    }

    /** 允许超收量 T(q, p); 比例为空按 0, 数量为空按 0。 */
    public static BigDecimal toleranceQty(BigDecimal qty, BigDecimal pct) {
        if (qty == null || pct == null || qty.signum() <= 0 || pct.signum() <= 0) {
            return BigDecimal.ZERO.setScale(MoneyPolicy.QUANTITY_SCALE);
        }
        return MoneyPolicy.quantity(qty.multiply(pct).movePointLeft(2));
    }

    /**
     * 本次收货后实际用到的允许超收量:
     * T_used = clamp(本次后累计有效收货 − 已授权基数, 0, T)。
     * 已授权基数 = 订货量 + 已过账财务批准超量 + 本单财务批准超量(都不含 T)。
     */
    public static BigDecimal usedTolerance(BigDecimal cumulativeQty, BigDecimal authorizedBaseQty, BigDecimal toleranceQty) {
        if (cumulativeQty == null || authorizedBaseQty == null || toleranceQty == null || toleranceQty.signum() <= 0) {
            return BigDecimal.ZERO;
        }
        return cumulativeQty.subtract(authorizedBaseQty).max(BigDecimal.ZERO).min(toleranceQty);
    }

    /**
     * 批准后改量下限: 最小的 4 位小数订货量 N, 使 N + T(N, p) ≥ requiredQty
     * (requiredQty = 净保留收货量 − 已过账超量, 订货单位)。先算 CEIL4(requiredQty / (1 + p/100)),
     * 再按 T 的四舍五入逐 0.0001 正向核验(不足加、仍满足就减), 与数据库收货守卫逐位一致。
     */
    public static BigDecimal minimumOrderedQty(BigDecimal requiredQty, BigDecimal pct) {
        if (requiredQty == null || requiredQty.signum() <= 0) {
            return BigDecimal.ZERO.setScale(MoneyPolicy.QUANTITY_SCALE);
        }
        BigDecimal required = requiredQty.setScale(MoneyPolicy.QUANTITY_SCALE, RoundingMode.CEILING);
        if (pct == null || pct.signum() <= 0) {
            return required;
        }
        BigDecimal candidate = required.multiply(HUNDRED)
                .divide(HUNDRED.add(pct), MoneyPolicy.QUANTITY_SCALE, RoundingMode.CEILING);
        while (candidate.add(toleranceQty(candidate, pct)).compareTo(required) < 0) {
            candidate = candidate.add(QUANTITY_STEP);
        }
        while (candidate.compareTo(QUANTITY_STEP) > 0) {
            BigDecimal lower = candidate.subtract(QUANTITY_STEP);
            if (lower.add(toleranceQty(lower, pct)).compareTo(required) < 0) {
                break;
            }
            candidate = lower;
        }
        return candidate;
    }

    /**
     * 按总金额计价的明细: 超收部分按原约定比例(总金额 × 超收量 ÷ 订货量)计价, 只有「总金额 ÷ 数量」
     * 是有限小数时任意 4 位小数的超收量才能精确计价。除不尽就不能填写允许超收比例。
     */
    public static void requireExactTotalInputOverage(
            BigDecimal totalAmountInput, BigDecimal qty, BigDecimal pct, int lineNo) {
        if (totalAmountInput == null || pct == null || pct.signum() <= 0) {
            return;
        }
        try {
            MoneyPolicy.orderOverageAmount(QUANTITY_STEP, BigDecimal.ZERO, totalAmountInput, qty);
        } catch (ApiException inexact) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "第 " + lineNo + " 行按总金额计价，总金额除以数量除不尽，超收部分无法按原约定价精确计价，"
                            + "不能填写允许超收比例；请清空比例或改为按单价计价");
        }
    }
}
