package com.uten.imp.features.sales;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SalesOrderSourceQuoteUuidContractTest {

    @Test
    void v264NeverGuessesHistoricalRelationFromFreeTextAndProtectsNewWrites() throws IOException {
        String sql = source("src/main/resources/db/migration/"
                + "V264__sales_order_source_quote_uuid.sql");
        String normalized = canonical(sql);

        assertThat(normalized).contains("ALTER TABLE sales_orders ADD COLUMN source_quote_id UUID");
        assertThat(normalized).doesNotContain("UPDATE sales_orders");
        assertThat(normalized).doesNotContain("source_doc_no =");
        assertThat(normalized).contains("FOREIGN KEY (source_quote_id) REFERENCES sales_quotes(id)");
        assertThat(normalized).contains("ON DELETE RESTRICT NOT VALID");
        assertThat(normalized).contains("VALIDATE CONSTRAINT fk_sales_orders_source_quote");
        assertThat(normalized).contains("CREATE UNIQUE INDEX uq_sales_orders_active_source_quote");
    }

    @Test
    void runtimeConversionAndTraceUseQuoteUuidNotMutableBillNumber() throws IOException {
        String order = source("src/main/java/com/uten/imp/features/sales/order/SalesOrderService.java");
        String quote = source("src/main/java/com/uten/imp/features/sales/quote/SalesQuoteService.java");

        assertThat(order).contains("quoteRepo.findById(o.getSourceQuoteId())");
        assertThat(order).contains("o.setSourceQuoteId(sourceQuote.getId())");
        assertThat(order).doesNotContain("quoteRepo.findByBillNo(o.getSourceDocNo())");
        assertThat(order).doesNotContain("resolveSourceQuoteOwner");
        assertThat(quote).contains("WHERE source_quote_id = :quoteId");
        assertThat(quote).doesNotContain("WHERE source_doc_no = :billNo");
    }

    private static String source(String serverRelativePath) throws IOException {
        Path direct = Path.of(serverRelativePath);
        Path path = Files.exists(direct) ? direct : Path.of("server").resolve(serverRelativePath);
        return Files.readString(path, StandardCharsets.UTF_8);
    }

    private static String canonical(String value) {
        return value.replaceAll("\\s+", " ").trim();
    }
}
