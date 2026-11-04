package com.uten.imp.features.finance.asset.domain;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class StraightLineScheduleCalculatorTest {
    private AutoCloseable explicitUserChoice;
    @BeforeEach void explicitFourDecimalAllocationChoice(){
        // 场景输入而非产品默认（MoneyPolicyTest 同范式）：100/3、…/7 除不尽时本次按 4 位四舍五入核对。
        explicitUserChoice=com.uten.imp.common.finance.BusinessPrecisionContext.use(java.util.Map.of(
                "money.cumulative-share",new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(4,"HALF_UP")));
    }
    @AfterEach void releaseUserChoice()throws Exception{explicitUserChoice.close();}

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
    void exactProductsAndMoreThanFourDigitsAreConservedAndOldFrozenInstallmentsStayFrozen() {
        var amount=new BigDecimal("1234567890123456789012345.123456789012345678901234");
        var schedule=StraightLineScheduleCalculator.calculate(amount,new BigDecimal(".000001"),7,AssetPeriod.parse("2026-01"));
        assertThat(schedule.originalAmount()).isEqualByComparingTo(amount);
        assertThat(schedule.residualAmount()).isEqualByComparingTo(amount.multiply(new BigDecimal(".000001")));
        assertThat(schedule.lines().stream().map(StraightLineScheduleCalculator.ScheduleLine::amount).reduce(BigDecimal.ZERO,BigDecimal::add))
                .isEqualByComparingTo(schedule.depreciableAmount());
        var exact=StraightLineScheduleCalculator.calculateDeferred(new BigDecimal("100.000001"),2,AssetPeriod.parse("2026-01"));
        assertThat(exact.lines().getFirst().amount()).isEqualByComparingTo("50.0000005");
        var old=StraightLineScheduleCalculator.calculateFrozen(new BigDecimal("100.0001"),new BigDecimal("5.0000"),2,AssetPeriod.parse("2026-01"),BigDecimal.ZERO,new BigDecimal("47.5001"));
        assertThat(old.residualAmount()).isEqualByComparingTo("5");
        assertThat(old.lines().getFirst().amount()).isEqualByComparingTo("47.5001");
        assertThat(old.lines().getLast().amount()).isEqualByComparingTo("47.5000");
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
