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
            throw new ApiException(ErrorCode.FORBIDDEN, "制单人不能" + action + "自己的单据，请换一位同事处理");
        }
    }

    public static void requireCorporateGlBook(String bookType) {
        if (!"CORPORATE".equals(bookType)) {
            throw new ApiException(ErrorCode.CONFLICT, "只有法人账簿才能过总账");
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
                    "开始期间不能早于启用时的会计期间 " + activation);
        }
    }

    public static void requireDisposalMonthDepreciated(
            LocalDate disposalDate,
            String lastEffectiveDepreciationPeriod) {
        if (disposalDate == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请填写生效日期");
        }
        String disposalPeriod = YearMonth.from(disposalDate).toString();
        if (!disposalPeriod.equals(lastEffectiveDepreciationPeriod)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "处置当月必须先计提折旧，才能做过账处置");
        }
    }
}
