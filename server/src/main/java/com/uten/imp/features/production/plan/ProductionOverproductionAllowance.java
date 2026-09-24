package com.uten.imp.features.production.plan;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.math.BigDecimal;

/** One numeric contract for manual plans, analysis issuance and their read-only previews. */
public final class ProductionOverproductionAllowance {
    public static final BigDecimal DEFAULT_RATE = new BigDecimal("0.10");

    private ProductionOverproductionAllowance() {}

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
