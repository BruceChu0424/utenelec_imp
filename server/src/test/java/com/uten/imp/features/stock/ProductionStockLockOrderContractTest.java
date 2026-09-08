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
                        "prelockproductiondocument(id)", "approveinternal(id, false, false)"},
                {"public stockdocdetail approveandissue(uuid id, stockdocissuerequest req)",
                        "lockproductiondocuments(list.of(id))", "requiredocforupdate(id)"},
                {"private stockdocdetail reverseinternal( uuid id, boolean finishedinboundconfirmationlane)",
                        "prelockproductiondocument(id)", "requiredocforupdate(id)"},
                {"public stockdocdetail reverseissue(uuid id, stockdocissuerequest req)",
                        "lockproductiondocuments(list.of(id))", "requiredrawforissue(id)"}
        };
        for (String[] command : commands) {
            String body = method(source, command[0]);
            assertThat(body.indexOf(command[1])).as(command[0]).isNotNegative()
                    .isLessThan(body.indexOf(command[2]));
        }
        // Java evaluates the complete prelock argument before entering the issue body.
        String issue = method(source, "public stockdocdetail issue(uuid id, stockdocissuerequest req)");
        assertThat(issue.replace(" ", "")).contains(
                "returnissueafterprelock(id,req,lockproductiondocuments(list.of(id)))");
        String prelude = method(source,
                "private fulfillmentmutationlocks.guard lockproductiondocuments(list<uuid> documentids)");
        assertThat(prelude.indexOf("mutationlocks.acquire("))
                .isNotNegative().isLessThan(prelude.indexOf("lockproductiondocumentgraphs(orderedids)"));
        assertThat(prelude).contains("mutationfootprints.forstockdocuments(orderedids)");
        String graph = method(source,
                "private void lockproductiondocumentgraphs(list<uuid> documentids)");
        assertThat(graph.indexOf("from plan_draw_links link"))
                .isNotNegative().isLessThan(graph.indexOf("from production_planning_packages package"));
        assertThat(graph.indexOf("from production_planning_packages package"))
                .isLessThan(graph.indexOf("from production_execution_segments segment"));
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
