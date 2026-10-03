package com.uten.imp.features.ai.gateway;

import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import static org.assertj.core.api.Assertions.*;

class AiPricingSnapshotTest {
    @Test void usesExactFrozenPerMillionRatesAndNeverFillsMissingUsageWithZero() {
        var snapshot = new AiCallLogService.PricingSnapshot("METERED", "USD", new BigDecimal("1.5"), new BigDecimal("3"), 7L);
        assertThat(snapshot.estimate(1000, 500)).isEqualByComparingTo("0.003");
        assertThat(snapshot.estimate(null, 500)).isNull();
        assertThat(snapshot.estimate(1000, null)).isNull();
        assertThat(snapshot.estimate(-1, 500)).isNull();
        assertThat(snapshot.estimate(0, 0)).isEqualByComparingTo(BigDecimal.ZERO);
    }
    @Test void subscriptionAndUnknownRatesCannotBePresentedAsPerCallCharges() {
        assertThat(new AiCallLogService.PricingSnapshot("SUBSCRIPTION", "CNY", null, null, 1L).estimate(1000, 500)).isNull();
        assertThat(new AiCallLogService.PricingSnapshot("METERED", "USD", null, BigDecimal.ONE, 1L).estimate(1000, 500)).isNull();
        assertThat(new AiCallLogService.PricingSnapshot("METERED", "USD", new BigDecimal("0.0000000001"), BigDecimal.ZERO, 1L).estimate(1, 0))
                .isEqualByComparingTo("0.0000000000000001");
    }
}
