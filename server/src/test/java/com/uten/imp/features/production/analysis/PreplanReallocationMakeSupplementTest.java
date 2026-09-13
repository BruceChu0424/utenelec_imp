package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;

class PreplanReallocationMakeSupplementTest {
    @Test void originalUnfinishedFourPlusYieldedFourOnlyAddsTheNewFour() {
        var allowance = new PreplanReallocationMakeSupplement.Allowance(
                UUID.randomUUID(),UUID.randomUUID(),new BigDecimal("4"),new BigDecimal("4"));
        assertThat(allowance.additional(new BigDecimal("8"),BigDecimal.ZERO)).isEqualByComparingTo("4");
        assertThat(allowance.additional(new BigDecimal("4"),BigDecimal.ZERO)).isZero();
    }
    @Test void OtherEffectiveSupplyAndPriorAttributedResponsibilityReduceNewMakeQuota() {
        var allowance = new PreplanReallocationMakeSupplement.Allowance(
                UUID.randomUUID(),UUID.randomUUID(),new BigDecimal("2"),BigDecimal.ZERO);
        assertThat(allowance.additional(new BigDecimal("4"),new BigDecimal("3"))).isEqualByComparingTo("1");
        assertThat(allowance.additional(new BigDecimal("10"),BigDecimal.ZERO)).isEqualByComparingTo("2");
        assertThat(PreplanReallocationMakeSupplement.Allowance.NONE.additional(new BigDecimal("1000"),BigDecimal.ZERO)).isZero();
    }
}
