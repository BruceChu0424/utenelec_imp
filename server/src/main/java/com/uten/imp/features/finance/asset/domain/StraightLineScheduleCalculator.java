package com.uten.imp.features.finance.asset.domain;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

/** Deterministic straight-line schedule; the final period absorbs all currency rounding. */
public final class StraightLineScheduleCalculator {

    /** Subledger and GL facts use NUMERIC(18,4); display layers may format fewer decimals. */
    private static final int MONEY_SCALE = 4;

    private StraightLineScheduleCalculator() {}

    public static Schedule calculate(
            BigDecimal originalAmount,
            BigDecimal residualRate,
            int usefulMonths,
            AssetPeriod startPeriod) {
        requirePositive(originalAmount, "originalAmount");
        Objects.requireNonNull(residualRate, "residualRate");
        Objects.requireNonNull(startPeriod, "startPeriod");
        if (residualRate.signum() < 0 || residualRate.compareTo(BigDecimal.ONE) > 0) {
            throw new IllegalArgumentException("residualRate must be between 0 and 1");
        }
        if (usefulMonths < 1 || usefulMonths > 1200) {
            throw new IllegalArgumentException("usefulMonths must be between 1 and 1200");
        }

        BigDecimal original = money(originalAmount);
        BigDecimal residual = money(original.multiply(residualRate));
        BigDecimal depreciable = original.subtract(residual);
        BigDecimal regular = depreciable.divide(BigDecimal.valueOf(usefulMonths), MONEY_SCALE, RoundingMode.HALF_UP);
        BigDecimal accumulated = BigDecimal.ZERO.setScale(MONEY_SCALE);
        List<ScheduleLine> lines = new ArrayList<>(usefulMonths);

        for (int sequence = 1; sequence <= usefulMonths; sequence++) {
            BigDecimal opening = accumulated;
            BigDecimal amount = sequence == usefulMonths
                    ? depreciable.subtract(accumulated)
                    : regular.min(depreciable.subtract(accumulated));
            amount = money(amount.max(BigDecimal.ZERO));
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

    public static Schedule calculateDeferred(
            BigDecimal totalAmount,
            int usefulMonths,
            AssetPeriod startPeriod) {
        return calculate(totalAmount, BigDecimal.ZERO, usefulMonths, startPeriod);
    }

    private static BigDecimal money(BigDecimal amount) {
        return amount.setScale(MONEY_SCALE, RoundingMode.HALF_UP);
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
