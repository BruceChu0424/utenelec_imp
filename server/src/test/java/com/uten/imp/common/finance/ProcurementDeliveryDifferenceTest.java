package com.uten.imp.common.finance;

import java.math.BigDecimal;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class ProcurementDeliveryDifferenceTest {
    @Test void historicalExamplesAndReturnsKeepTheirSignedMeaning() {
        assertThat(difference("300","0","0")).isEqualByComparingTo("-300");
        assertThat(difference("1300","106","0")).isEqualByComparingTo("-1194");
        assertThat(difference("100","100","3.1250")).isEqualByComparingTo("-3.1250");
        assertThat(difference("100","102","0")).isEqualByComparingTo("2");
    }

    @Test void exactDecimalFactsAndUnknownOrderedQuantityArePreserved() {
        assertThat(difference("9007199254740993.0001","0.0002","0.0001"))
                .isEqualByComparingTo("-9007199254740993.0000");
        assertThat(ProcurementDeliveryDifference.of(new BigDecimal("8.0001"),null,BigDecimal.ZERO)).isNull();
        assertThat(ProcurementDeliveryDifference.of(new BigDecimal("8.0001"),BigDecimal.ZERO,null)).isNull();
        assertThat(ProcurementDeliveryDifference.of(null,BigDecimal.ONE,BigDecimal.ZERO)).isNull();
    }

    @Test void requestDifferenceCountsApprovedPhysicalOrdersAndKeepsLegacyGiftsSeparate() {
        assertThat(ProcurementDeliveryDifference.request(ProcurementQuantities.EXTRA_GIFT,
                new BigDecimal("10"),new BigDecimal("2"),new BigDecimal("7"),new BigDecimal("1")))
                .isEqualByComparingTo("-4");
        assertThat(ProcurementDeliveryDifference.request(ProcurementQuantities.LEGACY,
                new BigDecimal("10"),new BigDecimal("2"),new BigDecimal("7"),BigDecimal.ZERO))
                .isEqualByComparingTo("-3");
        assertThat(ProcurementDeliveryDifference.balance(new BigDecimal("8"),BigDecimal.ZERO))
                .isEqualByComparingTo("-8");
        assertThat(ProcurementDeliveryDifference.balance(new BigDecimal("8"),new BigDecimal("8")))
                .isEqualByComparingTo("0");
        assertThat(ProcurementDeliveryDifference.balance(new BigDecimal("8"),new BigDecimal("10.5001")))
                .isEqualByComparingTo("2.5001");
        assertThat(ProcurementDeliveryDifference.request(ProcurementQuantities.EXTRA_GIFT,
                BigDecimal.TEN,null,BigDecimal.ONE,BigDecimal.ZERO)).isNull();
        assertThat(ProcurementDeliveryDifference.request(ProcurementQuantities.EXTRA_GIFT,
                BigDecimal.TEN,BigDecimal.ONE,null,BigDecimal.ZERO)).isNull();
        assertThat(ProcurementDeliveryDifference.request(ProcurementQuantities.EXTRA_GIFT,
                BigDecimal.TEN,BigDecimal.ONE,BigDecimal.ONE,null)).isNull();
        assertThat(ProcurementDeliveryDifference.balance(null,BigDecimal.ONE)).isNull();
    }

    private BigDecimal difference(String ordered,String received,String returned) {
        return ProcurementDeliveryDifference.of(new BigDecimal(ordered),new BigDecimal(received),new BigDecimal(returned));
    }
}
