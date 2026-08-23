package com.uten.imp.features.finance.payables;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class SubcontractLossValuationTest {

    @Test
    void excessLossRequiresPositiveSourceBookCost() {
        assertThatThrownBy(() -> SubcontractLossClaimService.requireValuedExcess(
                BigDecimal.ONE, BigDecimal.ZERO))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("超耗材料缺少有效发料账面成本");
    }

    @Test
    void allowedNormalLossDoesNotRequireAnAbnormalLossValuation() {
        assertThatCode(() -> SubcontractLossClaimService.requireValuedExcess(
                BigDecimal.ZERO, BigDecimal.ZERO)).doesNotThrowAnyException();
    }
}
