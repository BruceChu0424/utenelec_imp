package com.uten.imp.features.subcontract.short_delivery;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;

/** ADR-098 短交口径纯函数：允许下限、短交率、程度分档。 */
class SubcontractShortDeliveryPolicyTest {

    @Test
    void floorIsOrderedTimesOneMinusAllowedLoss() {
        assertThat(SubcontractShortDeliveryPolicy.floorQty(bd("100"), bd("5")))
                .isEqualByComparingTo("95.0000");
        assertThat(SubcontractShortDeliveryPolicy.floorQty(bd("33"), bd("5")))
                .isEqualByComparingTo("31.3500");
        assertThat(SubcontractShortDeliveryPolicy.floorQty(bd("100"), null)).isNull();
        assertThat(SubcontractShortDeliveryPolicy.floorQty(bd("100"), bd("100")))
                .isEqualByComparingTo("0");
    }

    @Test
    void deliveredAtOrAboveOrderedIsNotShort() {
        assertThat(SubcontractShortDeliveryPolicy.severity(bd("100"), bd("5"), bd("100"))).isNull();
        assertThat(SubcontractShortDeliveryPolicy.severity(bd("100"), bd("5"), bd("120"))).isNull();
        assertThat(SubcontractShortDeliveryPolicy.severity(bd("100"), null, bd("100"))).isNull();
    }

    @Test
    void withinToleranceWhenDeliveredReachesTheFloor() {
        assertThat(SubcontractShortDeliveryPolicy.severity(bd("100"), bd("5"), bd("95")))
                .isEqualTo(SubcontractShortDeliveryPolicy.WITHIN_TOLERANCE);
        assertThat(SubcontractShortDeliveryPolicy.severity(bd("100"), bd("5"), bd("99.5")))
                .isEqualTo(SubcontractShortDeliveryPolicy.WITHIN_TOLERANCE);
    }

    @Test
    void belowFloorSplitsIntoSevereAtTwiceToleranceOrTwentyPercent() {
        // 5%：低于 95 是 BELOW_FLOOR；短交率 >= max(10, 20) = 20% 才是 SEVERE。
        assertThat(SubcontractShortDeliveryPolicy.severity(bd("100"), bd("5"), bd("94")))
                .isEqualTo(SubcontractShortDeliveryPolicy.BELOW_FLOOR);
        assertThat(SubcontractShortDeliveryPolicy.severity(bd("100"), bd("5"), bd("81")))
                .isEqualTo(SubcontractShortDeliveryPolicy.BELOW_FLOOR);
        assertThat(SubcontractShortDeliveryPolicy.severity(bd("100"), bd("5"), bd("80")))
                .isEqualTo(SubcontractShortDeliveryPolicy.SEVERE);
        // 15%：阈值 max(30, 20) = 30%。
        assertThat(SubcontractShortDeliveryPolicy.severity(bd("100"), bd("15"), bd("75")))
                .isEqualTo(SubcontractShortDeliveryPolicy.BELOW_FLOOR);
        assertThat(SubcontractShortDeliveryPolicy.severity(bd("100"), bd("15"), bd("70")))
                .isEqualTo(SubcontractShortDeliveryPolicy.SEVERE);
    }

    @Test
    void unsetToleranceIsNeutralWheneverShort() {
        assertThat(SubcontractShortDeliveryPolicy.severity(bd("100"), null, bd("1")))
                .isEqualTo(SubcontractShortDeliveryPolicy.UNSET_TOLERANCE);
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
        assertThat(SubcontractShortDeliveryPolicy.allowedLossQty(bd("100"), bd("5")))
                .isEqualByComparingTo("5");
        assertThat(SubcontractShortDeliveryPolicy.allowedLossQty(bd("100"), null))
                .isEqualByComparingTo("0");
        assertThat(SubcontractShortDeliveryPolicy.severeThresholdPct(bd("5")))
                .isEqualByComparingTo("20");
        assertThat(SubcontractShortDeliveryPolicy.severeThresholdPct(bd("15")))
                .isEqualByComparingTo("30");
    }

    private static BigDecimal bd(String value) {
        return new BigDecimal(value);
    }

    @Test void finiteThresholdAndOneQuantumShortfallRemainExact(){
        assertThat(SubcontractShortDeliveryPolicy.floorQty(bd("0.000000000000000000000001"),bd("0.000000000000000000000001")))
                .isEqualByComparingTo("0.00000000000000000000000099999999999999999999999999");
        assertThat(SubcontractShortDeliveryPolicy.shortfallQty(bd("1"),bd("0.999999999999999999999999")))
                .isEqualByComparingTo("0.000000000000000000000001");
    }

    @Test void severityCannotFlipBecauseASelectedPercentRoundsToTheThreshold() throws Exception {
        try(var ignored=com.uten.imp.common.finance.BusinessPrecisionContext.use(java.util.Map.of(
                SubcontractShortDeliveryPolicy.PERCENT_PURPOSE,new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(0,"HALF_UP")))){
            assertThat(SubcontractShortDeliveryPolicy.shortfallPct(bd("3"),bd("2.400000000000000000000001")))
                    .isEqualByComparingTo("20");
            assertThat(SubcontractShortDeliveryPolicy.severity(bd("3"),bd("5"),bd("2.400000000000000000000001")))
                    .isEqualTo(SubcontractShortDeliveryPolicy.BELOW_FLOOR);
            assertThat(SubcontractShortDeliveryPolicy.severity(bd("3"),bd("5"),bd("2.4")))
                    .isEqualTo(SubcontractShortDeliveryPolicy.SEVERE);
        }
    }

    @Test void repeatingPercentHasNoImplicitTwoPlaceDefault(){
        org.assertj.core.api.Assertions.assertThatThrownBy(()->SubcontractShortDeliveryPolicy.shortfallPct(bd("3"),bd("2")))
                .isInstanceOf(com.uten.imp.common.finance.BusinessPrecisionRequiredException.class);
    }
}
