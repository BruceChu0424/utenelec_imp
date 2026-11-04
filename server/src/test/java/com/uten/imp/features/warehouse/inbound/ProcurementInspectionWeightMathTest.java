package com.uten.imp.features.warehouse.inbound;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;

class ProcurementInspectionWeightMathTest {

    @Test
    void cumulativePassSlicesConserveTheReceivedActualTotalWeight() throws Exception {
        BigDecimal totalWeight = new BigDecimal("10.0000");
        BigDecimal receivedBase = new BigDecimal("3.0000");

        // 10/3 除不尽：本次按 4 位四舍五入的显式选择切片，末片收回来源余额（MoneyPolicyTest 同范式）。
        try(var ignored=com.uten.imp.common.finance.BusinessPrecisionContext.use(java.util.Map.of(
                "quantity.slice",new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(4,"HALF_UP")))){
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

        // 有限商完整保留（0.0247×1/2=0.01235 精确），末片取真实余数, 两侧相加仍恰好等于来源金额;
        // 不再按旧 4 位 ROUND 隐藏投影（业务精度显式选择机制）。
        BigDecimal failedFirst=ProcurementInspectionService.releasedAmountSlice(
                receivedAmount,receivedBase,BigDecimal.ZERO,BigDecimal.ONE);
        BigDecimal passedLast=ProcurementInspectionService.releasedAmountSlice(
                receivedAmount,receivedBase,BigDecimal.ONE,BigDecimal.ONE);

        assertThat(failedFirst).isEqualByComparingTo("0.01235");
        assertThat(passedLast).isEqualByComparingTo("0.01235");
        assertThat(failedFirst.add(passedLast)).isEqualByComparingTo(receivedAmount);
    }
}
