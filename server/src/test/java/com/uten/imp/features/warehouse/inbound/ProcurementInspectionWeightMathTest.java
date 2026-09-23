package com.uten.imp.features.warehouse.inbound;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;

class ProcurementInspectionWeightMathTest {

    @Test
    void cumulativePassSlicesConserveTheReceivedActualTotalWeight() {
        BigDecimal totalWeight = new BigDecimal("10.0000");
        BigDecimal receivedBase = new BigDecimal("3.0000");

        BigDecimal first = ProcurementInspectionService.releasedWeightSlice(
                totalWeight, receivedBase, BigDecimal.ZERO, BigDecimal.ONE);
        BigDecimal second = ProcurementInspectionService.releasedWeightSlice(
                totalWeight, receivedBase, BigDecimal.ONE, BigDecimal.ONE);
        BigDecimal last = ProcurementInspectionService.releasedWeightSlice(
                totalWeight, receivedBase, new BigDecimal("2"), BigDecimal.ONE);

        assertThat(first.add(second).add(last))
                .isEqualByComparingTo(totalWeight);
        assertThat(last).isEqualByComparingTo("3.3333");
    }

    @Test
    void unknownReceivedWeightStaysUnknown() {
        assertThat(ProcurementInspectionService.releasedWeightSlice(
                null, BigDecimal.TEN, BigDecimal.ZERO, BigDecimal.ONE))
                .isNull();
    }

    @Test
    void interleavedFailAndPassShareOneResolvedCursorAndAbsorbFourDecimalTail() {
        BigDecimal receivedAmount=new BigDecimal("0.0247");
        BigDecimal receivedBase=new BigDecimal("2");

        // 4 位库存价值列: ROUND(来源 × 累计量 / 来源量, 4) 的差, 与 V446 库级守卫同式, 末片取余。
        BigDecimal failedFirst=ProcurementInspectionService.releasedAmountSlice(
                receivedAmount,receivedBase,BigDecimal.ZERO,BigDecimal.ONE);
        BigDecimal passedLast=ProcurementInspectionService.releasedAmountSlice(
                receivedAmount,receivedBase,BigDecimal.ONE,BigDecimal.ONE);

        assertThat(failedFirst).isEqualByComparingTo("0.0124");
        assertThat(passedLast).isEqualByComparingTo("0.0123");
        assertThat(failedFirst.add(passedLast)).isEqualByComparingTo(receivedAmount);
    }
}
