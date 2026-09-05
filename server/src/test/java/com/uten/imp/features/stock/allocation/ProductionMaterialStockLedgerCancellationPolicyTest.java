package com.uten.imp.features.stock.allocation;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionMaterialStockLedgerCancellationPolicyTest {

    @Test
    void readyAndHistoricalDispatchedCanCancelOnlyBeforeFirstReport() {
        assertThat(ProductionMaterialStockLedgerService
                .issueCancellationBlocked("READY", false)).isFalse();
        assertThat(ProductionMaterialStockLedgerService
                .issueCancellationBlocked("DISPATCHED", false)).isFalse();
        assertThat(ProductionMaterialStockLedgerService
                .issueCancellationBlocked("READY", true)).isTrue();
        assertThat(ProductionMaterialStockLedgerService
                .issueCancellationBlocked("DISPATCHED", true)).isTrue();
    }

    @Test
    void startedOrCompletedTaskAlwaysUsesMaterialReturn() {
        assertThat(ProductionMaterialStockLedgerService
                .issueCancellationBlocked("IN_PROGRESS", false)).isTrue();
        assertThat(ProductionMaterialStockLedgerService
                .issueCancellationBlocked("COMPLETED", false)).isTrue();
    }
}
