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
        if (input.acquisitionDate() == null) errors.add("acquisitionDate is required");
        if (input.acceptanceDate() == null) errors.add("acceptanceDate is required");
        if (input.readyForUseDate() == null) errors.add("readyForUseDate is required");
        if (input.acquisitionDate() != null && input.acceptanceDate() != null
                && input.acceptanceDate().isBefore(input.acquisitionDate())) {
            errors.add("acceptanceDate cannot precede acquisitionDate");
        }
        if (input.acceptanceDate() != null && input.readyForUseDate() != null
                && input.readyForUseDate().isBefore(input.acceptanceDate())) {
            errors.add("readyForUseDate cannot precede acceptanceDate");
        }
        if (input.readyForUseDate() != null && input.startPeriod() != null) {
            try {
                AssetPeriod derived = CorporateAssetBookPolicy.deriveDepreciationStart(input.readyForUseDate());
                if (!derived.equals(AssetPeriod.parse(input.startPeriod()))) {
                    errors.add("startPeriod must equal " + derived + " for the CORPORATE book");
                }
            } catch (IllegalArgumentException ignored) {
                // commonErrors already reports an invalid period.
            }
        }
        if (input.salvageRate() == null || input.salvageRate().signum() < 0
                || input.salvageRate().compareTo(BigDecimal.ONE) > 0) {
            errors.add("salvageRate must be between 0 and 1");
        } else if (input.amount() != null && input.amount().signum() > 0
                && input.usefulMonths() != null && input.usefulMonths() > 0
                && input.amount().multiply(BigDecimal.ONE.subtract(input.salvageRate()))
                    .divide(BigDecimal.valueOf(input.usefulMonths()), 4, RoundingMode.HALF_UP).signum() <= 0) {
            errors.add("monthly depreciation must be positive at four-decimal ledger precision");
        }
        reject(errors);
    }

    public static void validateDeferredExpense(DeferredInput input) {
        List<String> errors = commonErrors(
                input.policy(), input.amount(), input.usefulMonths(), input.startPeriod(), false);
        if (input.benefitStartDate() == null) errors.add("benefitStartDate is required");
        if (input.benefitEndDate() == null) errors.add("benefitEndDate is required");
        if (input.benefitStartDate() != null && input.benefitEndDate() != null
                && input.benefitEndDate().isBefore(input.benefitStartDate())) {
            errors.add("benefitEndDate cannot precede benefitStartDate");
        }
        if (input.benefitStartDate() != null && input.startPeriod() != null) {
            try {
                YearMonth start = AssetPeriod.parse(input.startPeriod()).value();
                if (!start.equals(YearMonth.from(input.benefitStartDate()))) {
                    errors.add("startPeriod must equal the benefitStartDate calendar month");
                }
                if (input.benefitEndDate() != null && input.usefulMonths() != null
                        && input.usefulMonths() > 0
                        && !start.plusMonths(input.usefulMonths() - 1L)
                                .equals(YearMonth.from(input.benefitEndDate()))) {
                    errors.add("startPeriod plus usefulMonths must end in the benefitEndDate calendar month");
                }
            } catch (IllegalArgumentException ignored) {
                // commonErrors already reports an invalid period.
            }
        }
        if (input.amount() != null && input.amount().signum() > 0
                && input.usefulMonths() != null && input.usefulMonths() > 0
                && input.amount().divide(BigDecimal.valueOf(input.usefulMonths()), 4, RoundingMode.HALF_UP)
                    .signum() <= 0) {
            errors.add("monthly amortization must be positive at four-decimal ledger precision");
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
        if (policy == null || policy.categoryId() == null) errors.add("categoryId is required");
        if (policy == null || policy.costStyleId() == null) errors.add("cost account is required");
        if (accumulatedAccountRequired && (policy == null || policy.accumulatedStyleId() == null)) {
            errors.add("accumulated account is required");
        }
        if (policy == null || policy.expenseStyleId() == null) errors.add("expense account is required");
        if (policy == null || policy.clearingStyleId() == null) errors.add("clearing account is required");
        if (amount == null || amount.signum() <= 0) errors.add("amount must be positive");
        if (usefulMonths == null || usefulMonths < 1 || usefulMonths > 1200) {
            errors.add("usefulMonths must be between 1 and 1200");
        }
        try {
            AssetPeriod.parse(startPeriod);
        } catch (IllegalArgumentException exception) {
            errors.add("startPeriod must be a valid calendar month");
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
