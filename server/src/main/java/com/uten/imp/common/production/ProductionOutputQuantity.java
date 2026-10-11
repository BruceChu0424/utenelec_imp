package com.uten.imp.common.production;

import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.math.BigDecimal;

/** Physical output must be representable by the existing four-place stock quantity ledger. */
public final class ProductionOutputQuantity {
    private ProductionOutputQuantity() { }

    public static BigDecimal requirePositiveBaseQuantity(BigDecimal qty, BigDecimal unitRate) {
        BigDecimal rate = unitRate == null ? BigDecimal.ONE : unitRate;
        if (qty == null || qty.signum() <= 0 || rate.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "报工数量和单位换算率必须大于零");
        }
        // The report itself stores NUMERIC(18,4), even if a small rate would
        // shrink an otherwise unstoreable nominal quantity. Validate before
        // multiplication/rounding, without expanding adversarial exponents.
        BigDecimal declared = FinancialExactAmount.quantity(qty, "报工数量");
        BigDecimal frozenRate = FinancialExactAmount.rate(rate, "单位换算率");
        BigDecimal base = MoneyPolicy.quantity(declared.multiply(frozenRate));
        if (base.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "换算后的基本量不足0.0001，请核对数量和单位换算率");
        }
        FinancialExactAmount.quantity(base, "换算后的基本量");
        return base;
    }
}
