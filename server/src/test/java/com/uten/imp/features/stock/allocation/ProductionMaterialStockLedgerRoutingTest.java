package com.uten.imp.features.stock.allocation;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ProductionMaterialStockLedgerRoutingTest {

    @Test
    void versionOneUsesExactDemandMapping() {
        assertThat(ProductionMaterialStockLedgerService
                .usesExactDemandMapping((short) 1)).isTrue();
    }

    @Test
    void versionZeroUsesOnlyLegacyConsumption() {
        assertThat(ProductionMaterialStockLedgerService
                .usesExactDemandMapping((short) 0)).isFalse();
    }

    @Test
    void unknownExecutionModelFailsClosed() {
        assertThatThrownBy(() -> ProductionMaterialStockLedgerService
                .usesExactDemandMapping((short) 2))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode())
                        .isEqualTo(ErrorCode.CONFLICT));
    }
}
