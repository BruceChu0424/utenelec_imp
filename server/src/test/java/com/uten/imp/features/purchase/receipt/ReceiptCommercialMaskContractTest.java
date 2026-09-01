package com.uten.imp.features.purchase.receipt;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ReceiptCommercialMaskContractTest {

    @Test
    void purchaseReceiptMasksCommercialHeaderAndAmountSortSideChannel() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/purchase/receipt/PurchaseReceiptService.java"));

        assertThat(source)
                .contains("boolean priceMasked = !priceMasker.canViewPurchaseReceipt()")
                .contains("priceMasked\n                                ? Map.of(\"billDate\", \"billDate\")")
                .contains("mask ? null : r.getCurrencyId()")
                .contains("mask ? null : r.getExchangeRate()")
                .contains("mask ? null : r.getTaxRate()")
                .contains("mask ? null : r.getSettlementMethodId()");
    }

    @Test
    void subcontractReceiptMasksCommercialHeaderAndAmountSortSideChannel() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/subcontract/receipt/SubcontractReceiptService.java"));

        assertThat(source)
                .contains("boolean priceMasked = !priceMasker.canViewSubcontractReceipt()")
                .contains("priceMasked ? Map.of(\"billDate\", \"billDate\") : ALLOWED_SORT")
                .contains("mask ? null : r.getCurrencyId()")
                .contains("mask ? null : r.getExchangeRate()")
                .contains("mask ? null : r.getTaxRate()")
                .contains("mask ? null : r.getSettlementMethodId()");
    }
}
