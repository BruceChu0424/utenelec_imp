package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ProcurementReceiptIntentTest {
    @Test
    void partialFirstArrivalRequiresAnExplicitChoiceBetweenReplacementAndNewSupply() {
        assertThatThrownBy(() -> ProcurementIqcReplacementAllocationService.resolveIntent(
                null,new BigDecimal("8"),new BigDecimal("6")))
                .isInstanceOf(ApiException.class).hasMessageContaining("明确选择");
        assertThat(ProcurementIqcReplacementAllocationService.resolveIntent(
                "RETURN_REPLACEMENT",new BigDecimal("8"),new BigDecimal("6")))
                .isEqualTo("RETURN_REPLACEMENT");
        assertThat(ProcurementIqcReplacementAllocationService.resolveIntent(
                "NORMAL",new BigDecimal("8"),new BigDecimal("6"))).isEqualTo("NORMAL");
    }

    @Test
    void legacyClientsCanOnlyInferAnUnambiguousSource() {
        assertThat(ProcurementIqcReplacementAllocationService.resolveIntent(
                null,new BigDecimal("8"),BigDecimal.ZERO)).isEqualTo("RETURN_REPLACEMENT");
        assertThat(ProcurementIqcReplacementAllocationService.resolveIntent(
                null,BigDecimal.ZERO,new BigDecimal("6"))).isEqualTo("NORMAL");
        assertThatThrownBy(() -> ProcurementIqcReplacementAllocationService.resolveIntent(
                "RETURN_REPLACEMENT",BigDecimal.ZERO,new BigDecimal("6")))
                .isInstanceOf(ApiException.class).hasMessageContaining("没有已实际退回");
    }
}
