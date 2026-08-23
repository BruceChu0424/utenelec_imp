package com.uten.imp.features.finance.report;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class CustomerPrepaymentReportOrderChainContractTest {
    @Test
    void datedEventsExposeStableOrderChainAndHumanLabels() throws IOException {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/finance/report/FinanceReportService.java"),
                StandardCharsets.UTF_8).replaceAll("\\s+", " ");

        assertThat(source)
                .contains("COALESCE(sales_order.bill_no,'客户池')")
                .contains("string_agg(DISTINCT sales_order.bill_no")
                .contains("string_agg(DISTINCT sales_order.id::text")
                .contains("item.put(\"salesOrderIds\"")
                .contains("'预收到账'::text AS event_type_label")
                .contains("'预收转销应收'")
                .contains("'预收转销反转'");
    }
}
