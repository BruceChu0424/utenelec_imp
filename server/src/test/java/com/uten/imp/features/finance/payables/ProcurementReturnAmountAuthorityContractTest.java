package com.uten.imp.features.finance.payables;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProcurementReturnAmountAuthorityContractTest {
    private static final Path MAIN = Path.of("src", "main", "java", "com", "uten", "imp", "features");

    @Test
    void purchaseReturnUsesLockedReceiptCommercialFactsBeforeStockAndAp() throws IOException {
        String service = read("purchase", "ret", "PurchaseReturnService.java");
        String authority = read("purchase", "ret", "PurchaseReturnAmountAuthority.java");

        assertThat(service).contains("returnAmountAuthority.apply(r, items);");
        assertThat(service.indexOf("returnAmountAuthority.apply(r, items);"))
                .isLessThan(service.indexOf("applyMovement(r, it, StockService.DIR_OUT"));
        assertThat(authority)
                .contains("FROM purchase_receipt_items source_item")
                .contains("source_receipt.currency_id, source_receipt.exchange_rate")
                .contains("source_item.order_item_id, source_receipt.status")
                .contains("FOR UPDATE OF source_item, source_receipt")
                .contains("item.setAmountOriginal(amounts.original())")
                .contains("purchaseReturn.setTotalLocal(money(totalLocal))");
    }

    @Test
    void subcontractReturnUsesLockedReceiptCommercialFactsBeforeStockAndAp() throws IOException {
        String service = read("subcontract", "ret", "SubcontractReturnService.java");
        String authority = read("subcontract", "ret", "SubcontractReturnAmountAuthority.java");

        assertThat(service).contains("returnAmountAuthority.apply(r, items);");
        assertThat(service.indexOf("returnAmountAuthority.apply(r, items);"))
                .isLessThan(service.indexOf("applyMovement(r, it, StockService.DIR_OUT"));
        assertThat(authority)
                .contains("FROM subcontract_receipt_items source_item")
                .contains("source_receipt.currency_id, source_receipt.exchange_rate")
                .contains("source_item.order_item_id, source_receipt.status")
                .contains("FOR UPDATE OF source_item, source_receipt")
                .contains("item.setAmountOriginal(amounts.original())")
                .contains("subcontractReturn.setTotalLocal(money(totalLocal))");
    }

    private static String read(String... parts) throws IOException {
        Path file = MAIN;
        for (String part : parts) file = file.resolve(part);
        return Files.readString(file);
    }
}
