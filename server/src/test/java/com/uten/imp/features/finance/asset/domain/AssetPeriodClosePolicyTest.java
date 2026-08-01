package com.uten.imp.features.finance.asset.domain;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class AssetPeriodClosePolicyTest {

    @Test
    void acceptsReconciledZeroRunsAsCloseEvidence() {
        var evidence = new AssetPeriodClosePolicy.Evidence(
                true, true, 0, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO);
        assertThatCode(() -> AssetPeriodClosePolicy.requireClosable(evidence)).doesNotThrowAnyException();
    }

    @Test
    void failsClosedWhenEitherRunOrReconciliationIsMissing() {
        assertThatThrownBy(() -> AssetPeriodClosePolicy.requireClosable(
                new AssetPeriodClosePolicy.Evidence(
                        true, false, 0, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("Both depreciation");
        assertThatThrownBy(() -> AssetPeriodClosePolicy.requireClosable(
                new AssetPeriodClosePolicy.Evidence(
                        true, true, 0, new BigDecimal("1"), BigDecimal.ZERO, BigDecimal.ZERO)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("does not reconcile");
    }
}
