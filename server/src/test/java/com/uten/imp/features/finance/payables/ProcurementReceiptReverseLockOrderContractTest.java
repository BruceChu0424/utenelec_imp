package com.uten.imp.features.finance.payables;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProcurementReceiptReverseLockOrderContractTest {
    @Test
    void purchaseAndSubcontractReverseLockInventoryBeforeReceiptInspectionAndAp() throws Exception {
        assertOrder("purchase/receipt/PurchaseReceiptService.java",
                "productionSupply.lockPurchaseReceiptMutationDimensions(");
        assertOrder("subcontract/receipt/SubcontractReceiptService.java",
                "productionSupply.lockSubcontractReceiptMutationDimensions(");
    }

    private static void assertOrder(String relative, String mutationLock) throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/", relative));
        int reverse = source.indexOf("public ReceiptDetail reverse(UUID id)");
        String body = source.substring(reverse);
        int inventory = body.indexOf("stockService.lockInventory(prelockItems.stream()");
        int receipt = body.indexOf("requireReceiptForUpdate(id)");
        int inspection = body.indexOf("inspectionService.requireResolvedForReverse(");
        int ap = body.indexOf("arApService.reverseArAp(");
        assertThat(inventory).isGreaterThanOrEqualTo(0);
        assertThat(inventory).isLessThan(body.indexOf(mutationLock));
        assertThat(inventory).isLessThan(receipt);
        assertThat(receipt).isLessThan(inspection);
        assertThat(inspection).isLessThan(ap);
        assertThat(body).contains("requireSameInventoryDimensions(prelockItems, items)");
    }
}
