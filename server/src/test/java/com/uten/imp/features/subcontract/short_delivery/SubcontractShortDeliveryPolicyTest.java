package com.uten.imp.features.subcontract.short_delivery;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;

/** ADR-098 短交口径纯函数：允许下限、短交率、程度分档。 */
class SubcontractShortDeliveryPolicyTest {

    @Test void thousandTargetAndTenPercentMaterialBudgetRequireAtLeastThousandActualProducts() {
        assertThat(SubcontractShortDeliveryPolicy.floorQty(bd("1000"))).isEqualByComparingTo("1000");
        for(String actual:new String[]{"900","950","999.9999"})
            assertThat(SubcontractShortDeliveryPolicy.severity(bd("1000"), bd(actual)))
                    .isEqualTo(SubcontractShortDeliveryPolicy.BELOW_FLOOR);
        for(String actual:new String[]{"1000","1050","1100"})
            assertThat(SubcontractShortDeliveryPolicy.severity(bd("1000"), bd(actual))).isNull();
        assertThat(SubcontractShortDeliveryPolicy.allowedLossQty()).isZero();
    }

    @Test
    void finishedFloorIsTheWholeTargetRegardlessOfMaterialAllowance() {
        assertThat(SubcontractShortDeliveryPolicy.floorQty(bd("100")))
                .isEqualByComparingTo("100");
        assertThat(SubcontractShortDeliveryPolicy.floorQty(bd("33")))
                .isEqualByComparingTo("33");
        assertThat(SubcontractShortDeliveryPolicy.floorQty(bd("100"))).isEqualByComparingTo("100");
        assertThat(SubcontractShortDeliveryPolicy.floorQty(bd("100")))
                .isEqualByComparingTo("100");
    }

    @Test
    void deliveredAtOrAboveOrderedIsNotShort() {
        assertThat(SubcontractShortDeliveryPolicy.severity(bd("100"), bd("100"))).isNull();
        assertThat(SubcontractShortDeliveryPolicy.severity(bd("100"), bd("120"))).isNull();
        assertThat(SubcontractShortDeliveryPolicy.severity(bd("100"), bd("100"))).isNull();
    }

    @Test
    void reachingTheHistoricalDiscountedFloorDoesNotFulfillTheFinishedTarget() {
        assertThat(SubcontractShortDeliveryPolicy.severity(bd("100"), bd("95")))
                .isEqualTo(SubcontractShortDeliveryPolicy.BELOW_FLOOR);
        assertThat(SubcontractShortDeliveryPolicy.severity(bd("100"), bd("99.5")))
                .isEqualTo(SubcontractShortDeliveryPolicy.BELOW_FLOOR);
    }

    @Test
    void finishedShortfallSeverityDoesNotDependOnTheMaterialBudget() {
        // 短交率不足 20% 是 BELOW_FLOOR；达到 20% 才是 SEVERE。
        assertThat(SubcontractShortDeliveryPolicy.severity(bd("100"), bd("94")))
                .isEqualTo(SubcontractShortDeliveryPolicy.BELOW_FLOOR);
        assertThat(SubcontractShortDeliveryPolicy.severity(bd("100"), bd("81")))
                .isEqualTo(SubcontractShortDeliveryPolicy.BELOW_FLOOR);
        assertThat(SubcontractShortDeliveryPolicy.severity(bd("100"), bd("80")))
                .isEqualTo(SubcontractShortDeliveryPolicy.SEVERE);
        // 25% 和 30% 的成品短交均为严重，阈值不来自材料预算。
        assertThat(SubcontractShortDeliveryPolicy.severity(bd("100"), bd("75")))
                .isEqualTo(SubcontractShortDeliveryPolicy.SEVERE);
        assertThat(SubcontractShortDeliveryPolicy.severity(bd("100"), bd("70")))
                .isEqualTo(SubcontractShortDeliveryPolicy.SEVERE);
    }

    @Test
    void missingMaterialAllowanceDoesNotHideARealFinishedShortfall() {
        assertThat(SubcontractShortDeliveryPolicy.severity(bd("100"), bd("1")))
                .isEqualTo(SubcontractShortDeliveryPolicy.SEVERE);
        assertThat(SubcontractShortDeliveryPolicy.isBelowFloor(SubcontractShortDeliveryPolicy.UNSET_TOLERANCE))
                .isFalse();
        assertThat(SubcontractShortDeliveryPolicy.isBelowFloor(SubcontractShortDeliveryPolicy.SEVERE)).isTrue();
        assertThat(SubcontractShortDeliveryPolicy.isBelowFloor(SubcontractShortDeliveryPolicy.BELOW_FLOOR)).isTrue();
    }

    @Test
    void shortfallFiguresAndAllowedShareUseOrderUnits() {
        assertThat(SubcontractShortDeliveryPolicy.shortfallQty(bd("100"), bd("60")))
                .isEqualByComparingTo("40");
        assertThat(SubcontractShortDeliveryPolicy.shortfallQty(bd("100"), bd("120")))
                .isEqualByComparingTo("0");
        assertThat(SubcontractShortDeliveryPolicy.shortfallPct(bd("100"), bd("60")))
                .isEqualByComparingTo("40.00");
        assertThat(SubcontractShortDeliveryPolicy.shortfallPct(bd("0"), bd("0")))
                .isEqualByComparingTo("0");
        assertThat(SubcontractShortDeliveryPolicy.allowedLossQty())
                .isEqualByComparingTo("0");
        assertThat(SubcontractShortDeliveryPolicy.allowedLossQty())
                .isEqualByComparingTo("0");
        assertThat(SubcontractShortDeliveryPolicy.severeThresholdPct())
                .isEqualByComparingTo("20");
        assertThat(SubcontractShortDeliveryPolicy.severeThresholdPct())
                .isEqualByComparingTo("20");
    }

    private static BigDecimal bd(String value) {
        return new BigDecimal(value);
    }

    @Test void finiteThresholdAndOneQuantumShortfallRemainExact(){
        assertThat(SubcontractShortDeliveryPolicy.floorQty(bd("0.000000000000000000000001")))
                .isEqualByComparingTo("0.000000000000000000000001");
        assertThat(SubcontractShortDeliveryPolicy.shortfallQty(bd("1"),bd("0.999999999999999999999999")))
                .isEqualByComparingTo("0.000000000000000000000001");
    }

    @Test void severityCannotFlipBecauseASelectedPercentRoundsToTheThreshold() throws Exception {
        try(var ignored=com.uten.imp.common.finance.BusinessPrecisionContext.use(java.util.Map.of(
                SubcontractShortDeliveryPolicy.PERCENT_PURPOSE,new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(0,"HALF_UP")))){
            assertThat(SubcontractShortDeliveryPolicy.shortfallPct(bd("3"),bd("2.400000000000000000000001")))
                    .isEqualByComparingTo("20");
            assertThat(SubcontractShortDeliveryPolicy.severity(bd("3"), bd("2.400000000000000000000001")))
                    .isEqualTo(SubcontractShortDeliveryPolicy.BELOW_FLOOR);
            assertThat(SubcontractShortDeliveryPolicy.severity(bd("3"), bd("2.4")))
                    .isEqualTo(SubcontractShortDeliveryPolicy.SEVERE);
        }
    }

    @Test void repeatingPercentHasNoImplicitTwoPlaceDefault(){
        org.assertj.core.api.Assertions.assertThatThrownBy(()->SubcontractShortDeliveryPolicy.shortfallPct(bd("3"),bd("2")))
                .isInstanceOf(com.uten.imp.common.finance.BusinessPrecisionRequiredException.class);
    }
}
