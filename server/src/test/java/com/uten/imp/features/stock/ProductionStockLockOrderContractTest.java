package com.uten.imp.features.stock;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionStockLockOrderContractTest {

    @Test
    void warehouseCommandsRunTheCanonicalPreludeBeforeTheDocumentLock()
            throws Exception {
        String source = compact(Path.of(
                "src/main/java/com/uten/imp/features/stock/StockDocService.java"));

        String[][] commands = new String[][]{
                {"public stockdocdetail approve(uuid id)",
                        "approveinternal(id, false, false)"},
                {"public stockdocdetail approveandissue(uuid id, stockdocissuerequest req)",
                        "requiredocforupdate(id)"},
                {"private stockdocdetail reverseinternal( uuid id, boolean finishedinboundconfirmationlane)",
                        "requiredocforupdate(id)"},
                {"public stockdocdetail issue(uuid id, stockdocissuerequest req)",
                        "requiredrawforissue(id)"},
                {"public stockdocdetail reverseissue(uuid id, stockdocissuerequest req)",
                        "requiredrawforissue(id)"}
        };
        for (String[] command : commands) {
            String method = method(source, command[0]);
            assertThat(method.indexOf("prelockproductiondocument(id)"))
                    .as(command[0])
                    .isNotNegative()
                    .isLessThan(method.indexOf(command[1]));
        }
        String prelude = method(source,
                "private void prelockproductiondocument(uuid documentid)");
        assertThat(prelude.indexOf("stockservice.lockinventory(dimensions)"))
                .isNotNegative()
                .isLessThan(prelude.indexOf(
                        "lockproductiondocumentgraph(documentid)"));
        String graph = method(source,
                "private void lockproductiondocumentgraph(uuid documentid)");
        assertThat(graph.indexOf("from plan_draw_links link"))
                .isLessThan(graph.indexOf(
                        "from production_planning_packages package"));
        assertThat(graph.indexOf("from production_planning_packages package"))
                .isLessThan(graph.indexOf(
                        "from production_execution_segments segment"));
    }

    @Test
    void receiptDemotionLocksPackageThenSegmentThenDraw() throws Exception {
        String source = compact(Path.of(
                "src/main/java/com/uten/imp/features/production/fulfillment/"
                        + "ProductionExecutionReadinessService.java"));
        String method = method(source,
                "private void unwindpromotedsegment(uuid segmentid)");

        assertThat(method.indexOf(
                        "select id from production_planning_packages"))
                .isNotNegative()
                .isLessThan(method.indexOf(
                        "select package_id, status from production_execution_segments"));
        assertThat(method.indexOf(
                        "select package_id, status from production_execution_segments"))
                .isLessThan(method.indexOf(
                        "join stock_documents document"));
    }

    private static String method(String source, String signature) {
        int start = source.indexOf(signature);
        if (start < 0) throw new AssertionError("missing method: " + signature);
        int next = source.indexOf(" public ", start + signature.length());
        int nextPrivate = source.indexOf(" private ", start + signature.length());
        int end = next < 0 ? source.length() : next;
        if (nextPrivate >= 0 && nextPrivate < end) end = nextPrivate;
        return source.substring(start, end);
    }

    private static String compact(Path path) throws Exception {
        return Files.readString(path, StandardCharsets.UTF_8)
                .replaceAll("//[^\\r\\n]*", " ")
                .replaceAll("/\\*.*?\\*/", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}
