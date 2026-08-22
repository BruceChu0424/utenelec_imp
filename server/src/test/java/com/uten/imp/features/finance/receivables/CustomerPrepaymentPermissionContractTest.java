package com.uten.imp.features.finance.receivables;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class CustomerPrepaymentPermissionContractTest {
    @Test
    void allMoneyReadsAndMutationsRequireViewAndCompanyFinanceScope() throws IOException {
        String controller = source("features/finance/receivables/CustomerPrepaymentController.java");
        String receipts = source("features/finance/receipt/FinanceReceiptService.java");

        assertThat(controller)
                .contains("customer_prepayment:view') and hasAuthority('customer_prepayment:apply")
                .contains("customer_prepayment:view') and hasAuthority('customer_prepayment:reverse")
                .contains("finance:view:all");
        assertThat(receipts)
                .contains("equalsIgnoreCase('CUSTOMER_PREPAYMENT')")
                .contains("canViewCustomerPrepayment()")
                .contains("access.hasAuthority(\"customer_prepayment:view\")")
                .contains("access.hasAuthority(\"finance:view:all\")")
                .contains("cb.notEqual(root.get(\"receiptKind\"), \"CUSTOMER_PREPAYMENT\")")
                .contains("requirePrepaymentView(r)");
    }

    private static String source(String relative) throws IOException {
        return Files.readString(Path.of("src/main/java/com/uten/imp/").resolve(relative),
                StandardCharsets.UTF_8).replaceAll("\\s+", " ");
    }
}
