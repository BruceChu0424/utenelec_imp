package com.uten.imp.features.finance.report;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class CustomerPrepaymentReportIntegrityContractTest {
    @Test
    void reportsUseDatedArrivalApplicationAndReversalEventsWithoutTreatingAdvanceAsArCash()
            throws IOException {
        String service = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/finance/report/FinanceReportService.java"),
                StandardCharsets.UTF_8).replaceAll("\\s+", " ");
        String query = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/finance/receivables/CustomerPrepaymentQueryService.java"),
                StandardCharsets.UTF_8).replaceAll("\\s+", " ");
        String controller = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/finance/report/FinanceReportController.java"),
                StandardCharsets.UTF_8).replaceAll("\\s+", " ");

        assertThat(service)
                .contains("CUSTOMER_PREPAYMENT_RECEIPT_REVERSED")
                .contains("CUSTOMER_PREPAYMENT_APPLIED")
                .contains("CUSTOMER_PREPAYMENT_APPLICATION_REVERSED")
                .contains("batch.reversed_at AT TIME ZONE 'Asia/Shanghai'")
                .contains("COALESCE(receipt.reversed_at, receipt.updated_at)");
        // 收款核销明细与来源分配的守恒校验移到预付查询权威；历史应收单据不再参与可操作口径。
        assertThat(query)
                .contains("receipt.receipt_kind='AR_SETTLEMENT'")
                .contains("finance_receipt_source_allocations allocation")
                .contains("HAVING COALESCE(SUM(allocation.cash_original),0)<>line.amount_original")
                .contains("OR COALESCE(SUM(allocation.applied_book_local),0)<>COALESCE(line.applied_amount_local,line.amount_local)");
        assertThat(controller)
                .contains("/customer-prepayment/events")
                .contains("/statement/customer-prepayments")
                .contains("customer_prepayment:view")
                .contains("finance:view:all");
    }
}
