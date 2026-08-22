package com.uten.imp.features.finance.payables;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SupplierPayablePostingContractTest {

    @Test
    void purchaseAndSubcontractReceiptReturnPostingsCarryBothCurrenciesAndDueDate() throws IOException {
        String purchaseReceipt = source("purchase/receipt/PurchaseReceiptService.java");
        String purchaseReturn = source("purchase/ret/PurchaseReturnService.java");
        String subcontractReceipt = source("subcontract/receipt/SubcontractReceiptService.java");
        String subcontractReturn = source("subcontract/ret/SubcontractReturnService.java");

        assertThat(purchaseReceipt)
                .contains("SupplierPaymentTermService paymentTerms")
                .contains("r.getTotalLocal(), (short) 1, null, r.getTotalOriginal(), dueDate")
                .contains("r.getSettlementStyleLegacy(), List.of(), r.getSettlementMethodId()");
        assertThat(purchaseReturn)
                .contains("SupplierPaymentTermService paymentTerms")
                .contains("returnLocal, (short) 17, null, returnOriginal, dueDate")
                .contains("r.getSettlementStyleLegacy(), List.of(), r.getSettlementMethodId()");
        assertThat(subcontractReceipt)
                .contains("postAp(r, r.getTotalOriginal(), totalLocalOf(items), +1)")
                .contains("signedOriginal", "dueDate", "settlementStyleLegacy");
        assertThat(subcontractReturn)
                .contains("postAp(r, r.getTotalOriginal(), totalLocalOf(items), -1)")
                .contains("signedOriginal", "dueDate", "settlementStyleLegacy");
    }

    private static String source(String relative) throws IOException {
        return Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/", relative));
    }
}
