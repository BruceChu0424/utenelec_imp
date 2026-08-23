package com.uten.imp.features.stock;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionDrawOwnershipAndReverseGuardContractTest {

    private static final Path MAIN = Path.of("src/main/java/com/uten/imp/features");

    @Test
    void automaticDrawKeepsWorkerUnassignedWhenSegmentHasNoResponsibleEmployee()
            throws Exception {
        String packageCommand = source(
                "production/mrp/ProductionExecutionPackageCommandService.java");
        String packageDraw = slice(
                packageCommand,
                "private MrpGenerateResult createDraw(",
                "private void createMakeSupplyPegs(");
        assertThat(packageDraw)
                .contains("document.setWorkerId(segment.getResponsibleEmployeeId());")
                .contains("document.setMakerId(currentUser.requireEmployeeId());")
                .doesNotContain("? currentUser.requireEmployeeId()");

        String readiness = source(
                "production/fulfillment/ProductionExecutionReadinessService.java");
        String readinessDraw = slice(
                readiness,
                "private StockDocument createDraw(",
                "private UUID addDrawItem(");
        assertThat(readinessDraw)
                .contains("document.setWorkerId(responsibleEmployeeId);")
                .contains("document.setMakerId(currentUser.requireEmployeeId());")
                .doesNotContain("? currentUser.requireEmployeeId()");
    }

    @Test
    void invalidHistoricalIssueDimensionFailsBeforeLedgerReverse()
            throws Exception {
        String stock = source("stock/StockDocService.java");
        int reverse = stock.indexOf("public StockDocDetail reverseIssue(");
        int dimensionGuard = stock.indexOf(
                "requireReverseIssueDimensions(d, items, req)", reverse);
        int ledgerReverse = stock.indexOf(
                "productionMaterialLedger.prepareReverseIssue(", reverse);

        assertThat(reverse).isGreaterThanOrEqualTo(0);
        assertThat(dimensionGuard).isGreaterThan(reverse);
        assertThat(ledgerReverse).isGreaterThan(dimensionGuard);
        assertThat(stock)
                .contains("禁止通用反出库；请走专用领料历史对账修复")
                .doesNotContain("仅回减历史误增的 issued_qty")
                .doesNotContain(
                        "if (d.getWarehouseId() == null || baseQty.signum() == 0) return");
    }

    private static String source(String relative) throws Exception {
        return Files.readString(MAIN.resolve(relative), StandardCharsets.UTF_8);
    }

    private static String slice(String source, String startMarker, String endMarker) {
        int start = source.indexOf(startMarker);
        int end = source.indexOf(endMarker, start + startMarker.length());
        assertThat(start).isGreaterThanOrEqualTo(0);
        assertThat(end).isGreaterThan(start);
        return source.substring(start, end);
    }
}
