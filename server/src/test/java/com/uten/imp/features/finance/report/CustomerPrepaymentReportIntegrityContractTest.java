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
        String controller = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/finance/report/FinanceReportController.java"),
                StandardCharsets.UTF_8).replaceAll("\\s+", " ");

        assertThat(service)
                .contains("receipt.receipt_kind='AR_SETTLEMENT'")
                .contains("prepayment_offset_fact AS")
                .contains("allocation.target_amount_local AS applied_local")
                .contains("-allocation.target_amount_local")
                .contains("CUSTOMER_PREPAYMENT_RECEIPT_REVERSED")
                .contains("CUSTOMER_PREPAYMENT_APPLIED")
                .contains("CUSTOMER_PREPAYMENT_APPLICATION_REVERSED")
                .contains("batch.reversed_at AT TIME ZONE 'Asia/Shanghai'")
                .contains("COALESCE(receipt.reversed_at, receipt.updated_at)");
        assertThat(controller)
                .contains("/customer-prepayment/events")
                .contains("/statement/customer-prepayments")
                .contains("customer_prepayment:view")
                .contains("finance:view:all");
    }
}
