package com.uten.imp.features.finance.asset.domain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.time.LocalDate;
import java.time.YearMonth;
import java.util.UUID;

/** Cross-cutting maker/checker, book and disposal cut-off rules. */
public final class AssetPostingPolicy {

    private AssetPostingPolicy() {}

    public static void requireDifferentActor(UUID actorId, UUID makerId, String action) {
        if (actorId != null && actorId.equals(makerId)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "The maker cannot " + action + " their own document");
        }
    }

    public static void requireCorporateGlBook(String bookType) {
        if (!"CORPORATE".equals(bookType)) {
            throw new ApiException(ErrorCode.CONFLICT, "Only the CORPORATE book can post to the general ledger");
        }
    }

    public static void requireStartNotBeforeActivationPeriod(
            String startPeriod,
            String activationPeriod) {
        AssetPeriod start = AssetPeriod.parse(startPeriod);
        AssetPeriod activation = AssetPeriod.parse(activationPeriod);
        if (start.value().isBefore(activation.value())) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "startPeriod cannot precede activation GL period " + activation);
        }
    }

    public static void requireDisposalMonthDepreciated(
            LocalDate disposalDate,
            String lastEffectiveDepreciationPeriod) {
        if (disposalDate == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "effectiveDate is required");
        }
        String disposalPeriod = YearMonth.from(disposalDate).toString();
        if (!disposalPeriod.equals(lastEffectiveDepreciationPeriod)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "The disposal month must be depreciated before disposal posting");
        }
    }
}
