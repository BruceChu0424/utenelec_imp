package com.uten.imp.common.finance;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;

class ProcurementIqcReplacementAllocationMathTest {
    @Test
    void fullyReceivedReturnedSliceReleasesOnlyTheReplacementIncrement(){
        assertThat(ProcurementIqcReplacementAllocationService.incrementalExcess(
                new BigDecimal("10"),new BigDecimal("2"),new BigDecimal("10")))
                .isEqualByComparingTo("2");
        assertThat(ProcurementIqcReplacementAllocationService.incrementalExcess(
                new BigDecimal("100"),new BigDecimal("20"),new BigDecimal("100")))
                .isEqualByComparingTo("20");
    }

    @Test
    void ordinaryRemainderIsUsedBeforeReturnedSliceAndZeroPriceStillTracksQty(){
        assertThat(ProcurementIqcReplacementAllocationService.incrementalExcess(
                new BigDecimal("9"),new BigDecimal("2"),new BigDecimal("10")))
                .isEqualByComparingTo("1");
        assertThat(ProcurementIqcReplacementAllocationService.incrementalExcess(
                BigDecimal.ZERO,BigDecimal.ZERO,BigDecimal.ZERO))
                .isEqualByComparingTo(BigDecimal.ZERO);
    }

    @Test
    void alreadyConsumedReplacementDoesNotReopenMoreThanCurrentReceipt(){
        assertThat(ProcurementIqcReplacementAllocationService.incrementalExcess(
                new BigDecimal("12"),new BigDecimal("1.5"),new BigDecimal("10")))
                .isEqualByComparingTo("1.5");
    }
}
