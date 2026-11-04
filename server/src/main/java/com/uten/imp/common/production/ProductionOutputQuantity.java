package com.uten.imp.common.production;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.math.BigDecimal;
import java.math.RoundingMode;

/** Physical output must be representable by the existing four-place stock quantity ledger. */
public final class ProductionOutputQuantity {
    private static final BigDecimal FINITE_LIMIT = BigDecimal.ONE.scaleByPowerOfTen(40);
    /** NUMERIC(18,4) ledger capacity: at most 14 integer and 4 fraction digits. */
    private static final BigDecimal LEDGER_QUANTITY_LIMIT = BigDecimal.ONE.scaleByPowerOfTen(14);
    /** Daily report unit rates keep their NUMERIC(18,6) input capacity. */
    private static final BigDecimal LEDGER_RATE_LIMIT = BigDecimal.ONE.scaleByPowerOfTen(12);

    private ProductionOutputQuantity() { }

    public static BigDecimal requirePositiveBaseQuantity(BigDecimal qty, BigDecimal unitRate) {
        BigDecimal rate = unitRate == null ? BigDecimal.ONE : unitRate;
        if (qty == null || qty.signum() <= 0 || rate.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "报工数量和单位换算率必须大于零");
        }
        // The report itself stores NUMERIC(18,4), even if a small rate would
        // shrink an otherwise unstoreable nominal quantity. Validate before the
        // multiplication/rounding, without expanding adversarial exponents.
        BigDecimal declared = ledgerInput(qty, "报工数量", 4, LEDGER_QUANTITY_LIMIT);
        BigDecimal frozenRate = ledgerInput(rate, "单位换算率", 6, LEDGER_RATE_LIMIT);
        // The output ledger stays four-place: the converted base is quantized to its
        // 0.0001 quantum here. MoneyPolicy.quantity no longer rounds and
        // FinancialExactAmount no longer enforces this ledger's capacity, so both
        // the rounding and the bounds live in this class explicitly.
        BigDecimal base = declared.multiply(frozenRate).setScale(4, RoundingMode.HALF_UP);
        if (base.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "换算后的基本量不足0.0001，请核对数量和单位换算率");
        }
        ledgerInput(base, "换算后的基本量", 4, LEDGER_QUANTITY_LIMIT);
        return base;
    }

    /** Same contract the shared FinancialExactAmount quantity/rate guards applied to this ledger. */
    private static BigDecimal ledgerInput(BigDecimal value, String label, int fractionDigits, BigDecimal integerLimit) {
        if (value == null) throw invalid(label, "不能为空");
        // Remove representational zeros only. This also avoids expanding a
        // value carrying an adversarially large exponent.
        BigDecimal exact = value.stripTrailingZeros();
        if (exact.abs().compareTo(FINITE_LIMIT) >= 0) {
            throw invalid(label, "超出可无损保存的金额范围，请核对原始单据；本次未保存");
        }
        if (exact.scale() > fractionDigits || exact.abs().compareTo(integerLimit) >= 0) {
            throw invalid(label, "超出可无损保存的范围(小数最多" + fractionDigits + "位)，请核对原值；本次未保存");
        }
        return exact;
    }

    private static ApiException invalid(String label, String reason) {
        return new ApiException(ErrorCode.VALIDATION_FAILED,
                (label == null || label.isBlank() ? "金额" : label) + reason);
    }
}
