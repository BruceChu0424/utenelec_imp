package com.uten.imp.common.integrity;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class OperationalCommercialSignGuardWiringTest {

    private static final Path FEATURE_SOURCE =
            Path.of("src/main/java/com/uten/imp/features");
    private static final String STORED_GUARD_CALL =
            "requireNonNegativeStoredCommercial(r, items);";

    @Test
    void allThreeOperationalDocumentsValidateRequestsAndStoredState() throws IOException {
        assertWired(read("purchase/receipt/PurchaseReceiptService.java"));
        assertWired(read("purchase/ret/PurchaseReturnService.java"));
        assertWired(read("sales/ret/SalesReturnService.java"));
    }

    @Test
    void persistedGuardsRunBeforeApprovalAndReversalEffects() throws IOException {
        String receipt = read("purchase/receipt/PurchaseReceiptService.java");
        assertBefore(method(receipt, "public ReceiptDetail approve(UUID id)",
                        "public ReceiptDetail reverse(UUID id)"),
                STORED_GUARD_CALL, "normalizePersistedItemUnits(items);");
        assertBefore(method(receipt, "public ReceiptDetail reverse(UUID id)",
                        "private void applyMovement"),
                STORED_GUARD_CALL, "productionSupply.beforePurchaseReceiptReversed(id);");

        String purchaseReturn = read("purchase/ret/PurchaseReturnService.java");
        assertBefore(method(purchaseReturn, "public ReturnDetail approve(UUID id)",
                        "public ReturnDetail reverse(UUID id)"),
                STORED_GUARD_CALL, "normalizePersistedItemUnits(items);");
        assertBefore(method(purchaseReturn, "public ReturnDetail reverse(UUID id)",
                        "private void applyMovement"),
                STORED_GUARD_CALL, "arApService.reverseArAp");

        String salesReturn = read("sales/ret/SalesReturnService.java");
        assertBefore(method(salesReturn, "public ReturnDetail approve(UUID id)",
                        "public ReturnDetail reverse(UUID id)"),
                STORED_GUARD_CALL, "lockStoredSourceGraph(items);");
        assertBefore(method(salesReturn, "public ReturnDetail reverse(UUID id)",
                        "private void applyMovement"),
                STORED_GUARD_CALL, "lockStoredSourceGraph(items);");
    }

    @Test
    void salesReturnIncludesCostAmountInBothPhases() throws IOException {
        String source = read("sales/ret/SalesReturnService.java");
        String requestGuard = method(source,
                "NonNegativeCommercialSignGuard.requireRequestLine(",
                "SalesReturnItem it = new SalesReturnItem();");
        String storedGuard = method(source,
                "private static void requireNonNegativeStoredCommercial",
                "private void applyTotals");

        assertThat(requestGuard).contains("l.getCostAmount()");
        assertThat(storedGuard).contains("item.getCostAmount()");
    }

    private static void assertWired(String source) {
        assertThat(source)
                .contains("NonNegativeCommercialSignGuard.requireRequestLine(")
                .contains("private static void requireNonNegativeStoredCommercial")
                .contains("NonNegativeCommercialSignGuard.requireStoredTotals(")
                .contains("NonNegativeCommercialSignGuard.requireStoredLine(");
        assertThat(occurrences(source, STORED_GUARD_CALL)).isEqualTo(2);
    }

    private static void assertBefore(String method, String guard, String effect) {
        assertThat(method.indexOf(guard)).isGreaterThanOrEqualTo(0);
        assertThat(method.indexOf(effect)).isGreaterThanOrEqualTo(0);
        assertThat(method.indexOf(guard)).isLessThan(method.indexOf(effect));
    }

    private static String method(String source, String start, String end) {
        int from = source.indexOf(start);
        int to = source.indexOf(end, from + start.length());
        assertThat(from).isGreaterThanOrEqualTo(0);
        assertThat(to).isGreaterThan(from);
        return source.substring(from, to);
    }

    private static int occurrences(String source, String needle) {
        int count = 0;
        int from = 0;
        while ((from = source.indexOf(needle, from)) >= 0) {
            count++;
            from += needle.length();
        }
        return count;
    }

    private static String read(String relativePath) throws IOException {
        return Files.readString(FEATURE_SOURCE.resolve(relativePath), StandardCharsets.UTF_8);
    }
}
