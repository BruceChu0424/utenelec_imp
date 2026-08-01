package com.uten.imp.features.finance.asset.application;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class FinanceAssetFeatureGateTest {

    @Test
    void defaultEquivalentDisabledGateRejectsPostedWorkflow() {
        var gate = new FinanceAssetFeatureGate(false);

        assertThatThrownBy(() -> gate.requirePostedWorkflowsEnabled("Initial recognition activation"))
                .isInstanceOfSatisfying(ApiException.class, exception -> {
                    assertThat(exception.getCode()).isEqualTo(ErrorCode.CONFLICT);
                    assertThat(exception.getMessage()).contains("reversal workflow");
                });
    }

    @Test
    void explicitlyEnabledGateAllowsServiceToContinueToDomainChecks() {
        var gate = new FinanceAssetFeatureGate(true);

        assertThatCode(() -> gate.requirePostedWorkflowsEnabled("Initial recognition activation"))
                .doesNotThrowAnyException();
    }
}
