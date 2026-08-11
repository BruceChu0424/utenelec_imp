package com.uten.imp.features.finance.asset.domain;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class StraightLineScheduleCalculatorTest {

    @Test
    void finalPeriodAbsorbsRoundingRemainder() {
        var schedule = StraightLineScheduleCalculator.calculateDeferred(
                new BigDecimal("100.00"), 3, AssetPeriod.parse("2026-01"));

        assertThat(schedule.lines()).extracting(StraightLineScheduleCalculator.ScheduleLine::amount)
                .containsExactly(new BigDecimal("33.3333"), new BigDecimal("33.3333"), new BigDecimal("33.3334"));
        assertThat(schedule.lines().getLast().closingNetAmount()).isEqualByComparingTo("0.0000");
        assertThat(schedule.lines()).extracting(StraightLineScheduleCalculator.ScheduleLine::period)
                .containsExactly("2026-01", "2026-02", "2026-03");
    }

    @Test
    void zeroResidualRateIsSupportedWithoutChangingTheFormula() {
        var schedule = StraightLineScheduleCalculator.calculate(
                new BigDecimal("1200"), BigDecimal.ZERO, 12, AssetPeriod.parse("2026-01"));

        assertThat(schedule.residualAmount()).isEqualByComparingTo("0.00");
        assertThat(schedule.lines().getLast().closingNetAmount()).isEqualByComparingTo("0.00");
    }

    @Test
    void rejectsMalformedOrNonCalendarPeriods() {
        assertThatThrownBy(() -> AssetPeriod.parse("2026-1")).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> AssetPeriod.parse("2026-13")).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> AssetPeriod.parse("0000-01")).isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void enforcesStrictPeriodContinuity() {
        AssetPeriod january = AssetPeriod.parse("2026-01");
        AssetPeriod.parse("2026-02").requireImmediatelyAfter(january);
        assertThatThrownBy(() -> AssetPeriod.parse("2026-03").requireImmediatelyAfter(january))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("expected 2026-02");
    }
}
