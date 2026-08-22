package com.uten.imp.features.finance.payables;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SupplierPayableHistoricalStatementContractTest {
    private static final Path MAIN = Path.of("src", "main", "java", "com", "uten", "imp", "features");

    @Test
    void monthlyFreezeValidatesTheExactSnapshotRowsPaymentMethod() throws Exception {
        String service = read("finance", "payables", "SupplierSettlementService.java");

        assertThat(service)
                .contains("source.settlement_type_id")
                .contains("moneyValue(row[17]),moneyValue(row[18]),uuid(row[19])")
                .contains("assertSettlementMethodConsistency(lines, request.settlementMethodId())")
                .contains("line.settlementMethodId(), settlementMethodId");
        assertThat(service.indexOf("assertSettlementMethodConsistency(lines, request.settlementMethodId())"))
                .isLessThan(service.indexOf("Totals totals = totals(lines)"));
    }

    @Test
    void supplierFlowDetailAndAnnualShareOneDatedApEventAuthority() throws Exception {
        String report = read("finance", "report", "FinanceReportService.java")
                .replace("\r\n", "\n");

        assertThat(count(report, "supplierPayableStatementEventsSql(documentScope)"))
                .as("flow, detail and annual must call the same event authority")
                .isEqualTo(3);
        assertThat(report)
                .contains("(ledger.deleted_at AT TIME ZONE 'Asia/Shanghai')::DATE")
                .contains("(payment.updated_at AT TIME ZONE 'Asia/Shanghai')::DATE AS reverse_date")
                .contains("(allocation.reversed_at AT TIME ZONE 'Asia/Shanghai')::DATE")
                .contains("line.applied_amount_local")
                .contains("payment.book_local")
                .contains("AS book_rate")
                .contains("payment.book_original,payment.book_rate,payment.book_local")
                .contains("FROM supplier_open_item_offsets allocation")
                .contains("'应付抵销'")
                .contains("'贷项使用'")
                .contains("'抵销反转'")
                .contains("'贷项恢复'")
                .doesNotContain("ledger.deleted_at::DATE")
                .doesNotContain("payment.updated_at::DATE")
                .doesNotContain("allocation.reversed_at::DATE");
    }

    private static int count(String source, String token) {
        int count = 0;
        for (int index = 0; (index = source.indexOf(token, index)) >= 0; index += token.length()) {
            count++;
        }
        return count;
    }

    private static String read(String... parts) throws Exception {
        Path file = MAIN;
        for (String part : parts) file = file.resolve(part);
        return Files.readString(file);
    }
}
