package com.uten.imp.features.finance.asset.application;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class FinanceAssetSourceNormalizationTest {

    @Test
    void canonicalizesTypesAndTrimsStableSourceKeys() {
        assertThat(FinanceAssetWorkflowService.normalizeType("  purchase_receipt "))
                .isEqualTo("PURCHASE_RECEIPT");
        assertThat(FinanceAssetWorkflowService.normalizeRef(" INV-001 "))
                .isEqualTo("INV-001");
        assertThat(FinanceAssetWorkflowService.normalizeRef(" header "))
                .isEqualTo("header");
        assertThat(FinanceAssetWorkflowService.normalizeRef("  ")).isNull();
    }
}
