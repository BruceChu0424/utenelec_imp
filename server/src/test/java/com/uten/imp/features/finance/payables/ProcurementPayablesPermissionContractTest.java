package com.uten.imp.features.finance.payables;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProcurementPayablesPermissionContractTest {

    @Test
    void paymentPreviewCannotBypassTheCompanyWidePayablesReadBoundary() throws IOException {
        String controller = source("ProcurementPayablesController.java");
        String previewEndpoint = between(controller,
                "@PostMapping(\"/payment-preview\")",
                "public PaymentPreview paymentPreview");

        assertThat(previewEndpoint)
                .as("payment preview returns full supplier/open-item data and needs the same company-wide read authority")
                .contains("hasAuthority('finance:view:all')");
    }

    private static String between(String source, String start, String end) {
        int from = source.indexOf(start);
        int to = source.indexOf(end, from + start.length());
        assertThat(from).as("start marker %s", start).isGreaterThanOrEqualTo(0);
        assertThat(to).as("end marker %s", end).isGreaterThan(from);
        return source.substring(from, to);
    }

    private static String source(String file) throws IOException {
        return Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/finance/payables", file));
    }
}
