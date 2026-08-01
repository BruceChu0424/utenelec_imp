package com.uten.imp.features.finance.asset.domain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.time.LocalDate;
import java.time.YearMonth;

/** Corporate-book timing rules; tax-book timing is intentionally separate. */
public final class CorporateAssetBookPolicy {

    private CorporateAssetBookPolicy() {}

    public static AssetPeriod deriveDepreciationStart(LocalDate readyForUseDate) {
        if (readyForUseDate == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "readyForUseDate is required");
        }
        return new AssetPeriod(YearMonth.from(readyForUseDate).plusMonths(1));
    }

    public static void requireDerivedStart(LocalDate readyForUseDate, String requestedPeriod) {
        AssetPeriod derived = deriveDepreciationStart(readyForUseDate);
        if (!derived.equals(AssetPeriod.parse(requestedPeriod))) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "Corporate depreciation start must be " + derived + " for the ready-for-use date");
        }
    }
}
