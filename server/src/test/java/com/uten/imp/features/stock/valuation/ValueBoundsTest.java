package com.uten.imp.features.stock.valuation;

import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.math.RoundingMode;
import static org.assertj.core.api.Assertions.*;

class ValueBoundsTest {
    @Test void nonTerminatingWeightsRemainBoundsAndNeverBecomeRoundedSourceMoney(){
        ValueBounds original=ValueBounds.exact(new BigDecimal("1.0001"));
        ValueBounds first=original.weighted(BigDecimal.ZERO,BigDecimal.ONE,new BigDecimal("3"),32);
        ValueBounds remaining=original.weighted(BigDecimal.ONE,new BigDecimal("3"),new BigDecimal("3"),32);
        ValueBounds second=remaining.weighted(BigDecimal.ZERO,BigDecimal.ONE,new BigDecimal("2"),32);
        assertThat(first.isExact()).isFalse();assertThat(second.isExact()).isFalse();
        // Cross-multiplication checks an enclosing bound without approximating 1/3.
        assertThat(second.lower().multiply(new BigDecimal("3"))).isLessThanOrEqualTo(new BigDecimal("1.0001"));
        assertThat(second.upper().multiply(new BigDecimal("3"))).isGreaterThanOrEqualTo(new BigDecimal("1.0001"));
        ValueBounds two=first.add(second);
        assertThat(two.sameUnit(4,RoundingMode.HALF_UP)).isTrue();
        assertThat(two.lower().setScale(4,RoundingMode.HALF_UP)).isEqualByComparingTo("0.6667");
        assertThat(original.lower()).isEqualByComparingTo("1.0001");
    }

    @Test void finiteDivisionAndSourceInputAreNeverTrimmedToTheFourPlaceDisplay(){
        ValueBounds source=ValueBounds.exact(new BigDecimal("0.0001"));
        ValueBounds half=source.weighted(BigDecimal.ZERO,BigDecimal.ONE,new BigDecimal("2"),32);
        assertThat(half.isExact()).isTrue();assertThat(half.lower()).isEqualByComparingTo("0.00005");
        assertThat(half.add(half).lower()).isEqualByComparingTo("0.0001");
    }

    @Test void longFiniteChainsDoNotExpandUnboundedDecimalCoefficientsOnTheHotPath(){
        ValueBounds value=ValueBounds.exact(BigDecimal.ONE);
        for(int i=0;i<10000;i++)value=value.weighted(BigDecimal.ZERO,BigDecimal.ONE,new BigDecimal("2"),32);
        assertThat(value.lower().scale()).isLessThanOrEqualTo(128);
        assertThat(value.upper().precision()).isLessThanOrEqualTo(128);
        assertThat(value.lower()).isGreaterThanOrEqualTo(BigDecimal.ZERO);
        assertThat(value.upper()).isGreaterThan(BigDecimal.ZERO);
        assertThat(value.isExact()).isFalse();
    }
}
