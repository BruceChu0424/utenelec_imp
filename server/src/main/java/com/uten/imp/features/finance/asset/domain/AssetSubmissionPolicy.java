package com.uten.imp.features.finance.asset.domain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.YearMonth;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** Fail-closed submission checks for policy, accounting configuration and key dates. */
public final class AssetSubmissionPolicy {

    private AssetSubmissionPolicy() {}

    public static void validateFixedAsset(FixedAssetInput input) {
        List<String> errors = commonErrors(
                input.policy(), input.amount(), input.usefulMonths(), input.startPeriod(), true);
        if (input.acquisitionDate() == null) errors.add("请填写采购（取得）日期");
        if (input.acceptanceDate() == null) errors.add("请填写验收日期");
        if (input.readyForUseDate() == null) errors.add("请填写达到可使用状态的日期");
        if (input.acquisitionDate() != null && input.acceptanceDate() != null
                && input.acceptanceDate().isBefore(input.acquisitionDate())) {
            errors.add("验收日期不能早于采购（取得）日期");
        }
        if (input.acceptanceDate() != null && input.readyForUseDate() != null
                && input.readyForUseDate().isBefore(input.acceptanceDate())) {
            errors.add("可使用日期不能早于验收日期");
        }
        if (input.readyForUseDate() != null && input.startPeriod() != null) {
            try {
                AssetPeriod derived = CorporateAssetBookPolicy.deriveDepreciationStart(input.readyForUseDate());
                if (!derived.equals(AssetPeriod.parse(input.startPeriod()))) {
                    errors.add("法人账的折旧开始期间应为 " + derived);
                }
            } catch (IllegalArgumentException ignored) {
                // commonErrors already reports an invalid period.
            }
        }
        if (input.salvageRate() == null || input.salvageRate().signum() < 0
                || input.salvageRate().compareTo(BigDecimal.ONE) > 0) {
            errors.add("残值率必须在 0 到 1 之间");
        } else if (input.amount() != null && input.amount().signum() > 0
                && input.usefulMonths() != null && input.usefulMonths() > 0
                && input.amount().multiply(BigDecimal.ONE.subtract(input.salvageRate()))
                    .divide(BigDecimal.valueOf(input.usefulMonths()), 4, RoundingMode.HALF_UP).signum() <= 0) {
            errors.add("按 4 位小数算出的月折旧额是 0，请调整金额、残值率或月数");
        }
        reject(errors);
    }

    public static void validateDeferredExpense(DeferredInput input) {
        List<String> errors = commonErrors(
                input.policy(), input.amount(), input.usefulMonths(), input.startPeriod(), false);
        if (input.benefitStartDate() == null) errors.add("请填写受益开始日期");
        if (input.benefitEndDate() == null) errors.add("请填写受益结束日期");
        if (input.benefitStartDate() != null && input.benefitEndDate() != null
                && input.benefitEndDate().isBefore(input.benefitStartDate())) {
            errors.add("受益结束日期不能早于受益开始日期");
        }
        if (input.benefitStartDate() != null && input.startPeriod() != null) {
            try {
                YearMonth start = AssetPeriod.parse(input.startPeriod()).value();
                if (!start.equals(YearMonth.from(input.benefitStartDate()))) {
                    errors.add("开始期间必须与受益开始日期所在月份一致");
                }
                if (input.benefitEndDate() != null && input.usefulMonths() != null
                        && input.usefulMonths() > 0
                        && !start.plusMonths(input.usefulMonths() - 1L)
                                .equals(YearMonth.from(input.benefitEndDate()))) {
                    errors.add("开始期间加摊销月数推出的结束月必须与受益结束日期所在月份一致");
                }
            } catch (IllegalArgumentException ignored) {
                // commonErrors already reports an invalid period.
            }
        }
        if (input.amount() != null && input.amount().signum() > 0
                && input.usefulMonths() != null && input.usefulMonths() > 0
                && input.amount().divide(BigDecimal.valueOf(input.usefulMonths()), 4, RoundingMode.HALF_UP)
                    .signum() <= 0) {
            errors.add("按 4 位小数算出的月摊销额是 0，请调整金额或月数");
        }
        reject(errors);
    }

    private static List<String> commonErrors(
            PolicyInput policy,
            BigDecimal amount,
            Integer usefulMonths,
            String startPeriod,
            boolean accumulatedAccountRequired) {
        List<String> errors = new ArrayList<>();
        if (policy == null || policy.categoryId() == null) errors.add("请选择资产类别");
        if (policy == null || policy.costStyleId() == null) errors.add("请配置成本科目");
        if (accumulatedAccountRequired && (policy == null || policy.accumulatedStyleId() == null)) {
            errors.add("请配置累计折旧科目");
        }
        if (policy == null || policy.expenseStyleId() == null) errors.add("请配置费用科目");
        if (policy == null || policy.clearingStyleId() == null) errors.add("请配置清理科目");
        if (amount == null || amount.signum() <= 0) errors.add("金额必须大于 0");
        if (usefulMonths == null || usefulMonths < 1 || usefulMonths > 1200) {
            errors.add("折旧/摊销月数必须在 1 到 1200 之间");
        }
        try {
            AssetPeriod.parse(startPeriod);
        } catch (IllegalArgumentException exception) {
            errors.add("开始期间必须是正确的年月（YYYY-MM）");
        }
        return errors;
    }

    private static void reject(List<String> errors) {
        if (!errors.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, String.join("; ", errors));
        }
    }

    public record PolicyInput(
            UUID categoryId,
            UUID costStyleId,
            UUID accumulatedStyleId,
            UUID expenseStyleId,
            UUID clearingStyleId) {}

    public record FixedAssetInput(
            PolicyInput policy,
            BigDecimal amount,
            BigDecimal salvageRate,
            Integer usefulMonths,
            String startPeriod,
            LocalDate acquisitionDate,
            LocalDate acceptanceDate,
            LocalDate readyForUseDate) {}

    public record DeferredInput(
            PolicyInput policy,
            BigDecimal amount,
            Integer usefulMonths,
            String startPeriod,
            LocalDate benefitStartDate,
            LocalDate benefitEndDate) {}
}
