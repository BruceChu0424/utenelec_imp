package com.uten.imp.features.finance.asset.domain;

import java.math.BigDecimal;
import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.util.FinancialExactAmount;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

/** Deterministic straight-line schedule; source installments stay frozen and the final period retains the exact remainder. */
public final class StraightLineScheduleCalculator {

    private StraightLineScheduleCalculator() {}

    public static Schedule calculate(
            BigDecimal originalAmount,
            BigDecimal residualRate,
            int usefulMonths,
            AssetPeriod startPeriod) {
        return calculateOpening(originalAmount,residualRate,usefulMonths,startPeriod,BigDecimal.ZERO);
    }

    /** Opening accumulated depreciation is preserved; only the remaining depreciable amount is scheduled. */
    public static Schedule calculateOpening(BigDecimal originalAmount,BigDecimal residualRate,int usefulMonths,
            AssetPeriod startPeriod,BigDecimal openingAccumulated) {
        requirePositive(originalAmount, "originalAmount");
        Objects.requireNonNull(residualRate, "residualRate");
        Objects.requireNonNull(startPeriod, "startPeriod");
        if (residualRate.signum() < 0 || residualRate.compareTo(BigDecimal.ONE) > 0) {
            throw new IllegalArgumentException("residualRate must be between 0 and 1");
        }
        return calculateFrozen(originalAmount,originalAmount.multiply(residualRate),usefulMonths,startPeriod,openingAccumulated);
    }

    /** Existing approved books own their frozen residual; never rederive it from a later policy. */
    public static Schedule calculateFrozen(BigDecimal originalAmount,BigDecimal residualAmount,int usefulMonths,
            AssetPeriod startPeriod,BigDecimal openingAccumulated) {
        return calculateFrozen(originalAmount,residualAmount,usefulMonths,startPeriod,openingAccumulated,null);
    }
    public static Schedule calculateFrozen(BigDecimal originalAmount,BigDecimal residualAmount,int usefulMonths,
            AssetPeriod startPeriod,BigDecimal openingAccumulated,BigDecimal frozenRegularAmount) {
        requirePositive(originalAmount,"originalAmount");Objects.requireNonNull(startPeriod,"startPeriod");
        if (usefulMonths < 1 || usefulMonths > 1200) {
            throw new IllegalArgumentException("usefulMonths must be between 1 and 1200");
        }

        BigDecimal original = money(originalAmount);
        BigDecimal residual = money(Objects.requireNonNull(residualAmount));
        if(residual.signum()<0||residual.compareTo(original)>0)throw new IllegalArgumentException("residual amount exceeds original");
        BigDecimal depreciable = original.subtract(residual);
        BigDecimal accumulated = money(Objects.requireNonNull(openingAccumulated));
        if(accumulated.signum()<0||accumulated.compareTo(depreciable)>0)
            throw new IllegalArgumentException("opening accumulated depreciation exceeds depreciable amount");
        BigDecimal initialAccumulated=accumulated;
        List<ScheduleLine> lines = new ArrayList<>(usefulMonths);

        for (int sequence = 1; sequence <= usefulMonths; sequence++) {
            BigDecimal opening = accumulated;
            BigDecimal amount = periodAmount(depreciable,initialAccumulated,usefulMonths,sequence,accumulated,frozenRegularAmount);
            accumulated = money(accumulated.add(amount));
            lines.add(new ScheduleLine(
                    sequence,
                    startPeriod.value().plusMonths(sequence - 1L).toString(),
                    opening,
                    amount,
                    accumulated,
                    money(original.subtract(accumulated))));
        }
        return new Schedule(original, residual, depreciable, List.copyOf(lines));
    }

    /** O(1) posting calculation shared with schedule generation; last period absorbs the exact remainder. */
    public static BigDecimal periodAmount(BigDecimal depreciable,BigDecimal openingAccumulated,int months,
            int sequence,BigDecimal accumulatedBefore) {
        return periodAmount(depreciable,openingAccumulated,months,sequence,accumulatedBefore,null);
    }
    public static BigDecimal periodAmount(BigDecimal depreciable,BigDecimal openingAccumulated,int months,
            int sequence,BigDecimal accumulatedBefore,BigDecimal frozenRegularAmount) {
        if(months<1||months>1200||sequence<1||sequence>months||openingAccumulated.signum()<0
                ||accumulatedBefore.compareTo(openingAccumulated)<0||depreciable.compareTo(accumulatedBefore)<0)
            throw new IllegalArgumentException("Invalid depreciation period or accumulated balance");
        BigDecimal remaining=depreciable.subtract(accumulatedBefore);
        BigDecimal regular=frozenRegularAmount==null?regularAmount(depreciable.subtract(openingAccumulated),months):money(frozenRegularAmount);
        if(regular.signum()<0)throw new IllegalArgumentException("Invalid frozen installment");
        return money(sequence==months?remaining:regular.min(remaining));
    }
    public static BigDecimal regularAmount(BigDecimal remaining,int months){
        if(months<1||months>1200||remaining.signum()<0)throw new IllegalArgumentException("Invalid straight-line amount or months");
        return MoneyPolicy.cumulativeShare(remaining,BigDecimal.ONE,BigDecimal.valueOf(months));
    }

    public static Schedule calculateDeferred(
            BigDecimal totalAmount,
            int usefulMonths,
            AssetPeriod startPeriod) {
        return calculate(totalAmount, BigDecimal.ZERO, usefulMonths, startPeriod);
    }

    private static BigDecimal money(BigDecimal amount) {
        return FinancialExactAmount.canonicalMoney(amount,"资产账面金额");
    }

    private static void requirePositive(BigDecimal amount, String field) {
        Objects.requireNonNull(amount, field);
        if (amount.signum() <= 0) {
            throw new IllegalArgumentException(field + " must be positive");
        }
    }

    public record Schedule(
            BigDecimal originalAmount,
            BigDecimal residualAmount,
            BigDecimal depreciableAmount,
            List<ScheduleLine> lines) {}

    public record ScheduleLine(
            int sequence,
            String period,
            BigDecimal openingAccumulated,
            BigDecimal amount,
            BigDecimal closingAccumulated,
            BigDecimal closingNetAmount) {}
}
