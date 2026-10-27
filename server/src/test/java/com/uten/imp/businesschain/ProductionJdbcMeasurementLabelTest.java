package com.uten.imp.businesschain;

import java.util.List;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

class ProductionJdbcMeasurementLabelTest {
    @Test void onlyCompleteStandaloneProvenanceQueriesGetTheThreeSafetyLabels() {
        assertEquals("archive.mutable_origin", label("SELECT fn_imported_business_document(?,?)"));
        assertEquals("archive.mutable_origin", label(" SELECT\nfn_imported_business_document(?, ?) "));
        assertEquals("archive.metadata_origin", label("SELECT id, fn_imported_business_document(?,id) "
                + "FROM public.stock_documents WHERE id IN (?, ? , ?)"));
        assertEquals("archive.source_origin", label("SELECT id FROM public.subcontract_order_items "
                + "WHERE id IN (?) AND fn_imported_business_document(?,id)"));
    }

    @Test void ordinaryBusinessSelectorsWithOriginPredicatesStayInTheOriginalBudget() {
        for (String sql : List.of(
                "SELECT d.id,d.status FROM stock_documents d WHERE NOT fn_imported_business_document(?,d.id)",
                "SELECT id FROM public.stock_documents WHERE id IN (?) AND fn_imported_business_document(?,id) AND status=1",
                "SELECT id, fn_imported_business_document(?,id),amount_local FROM public.stock_documents WHERE id IN (?)",
                "SELECT fn_imported_business_document(?,?),count(*) FROM stock_documents",
                "SELECT fn_imported_business_document(?,?) FROM stock_documents",
                "WITH native AS (SELECT id FROM stock_documents WHERE NOT fn_imported_business_document(?,id)) SELECT * FROM native",
                "SELECT id FROM public.stock_documents WHERE id IN (?) AND NOT fn_imported_business_document(?,id)")) {
            assertFalse(label(sql).startsWith("archive."), sql);
        }
    }

    @Test void extraStatementsExpressionsAndUnboundIdListsCannotEscapeTheOriginalBudget() {
        for (String sql : List.of(
                "SELECT fn_imported_business_document(?,?); SELECT id FROM stock_documents",
                "SELECT coalesce(fn_imported_business_document(?,?),false)",
                "SELECT id FROM public.stock_documents WHERE id IN () AND fn_imported_business_document(?,id)",
                "SELECT id FROM public.stock_documents WHERE id IN (?,42) AND fn_imported_business_document(?,id)",
                "SELECT id FROM public.stock_documents WHERE id IN (?,current_setting('app.id')) AND fn_imported_business_document(?,id)",
                "SELECT id, fn_imported_business_document(?,id) FROM public.stock_documents WHERE id IN (?) ORDER BY id")) {
            assertFalse(label(sql).startsWith("archive."), sql);
        }
    }

    @Test void onlyTheStandaloneMovementMeasurementBooleanHasItsOwnSafetyLabel() {
        assertEquals("measurement.operability", label("SELECT fn_stock_measurement_usable(?,?,CAST(? AS uuid))"));
        assertEquals("measurement.operability", label("SELECT fn_stock_measurement_usable(?, ?, CAST(? AS UUID))"));
        for (String sql : List.of(
                "SELECT b.qty FROM stock_balances b WHERE fn_stock_measurement_usable(b.warehouse_id,b.goods_id,b.color_id)",
                "SELECT fn_stock_measurement_usable(?,?,CAST(? AS uuid)),amount_local FROM stock_balances",
                "WITH usable AS (SELECT fn_stock_measurement_usable(?,?,CAST(? AS uuid))) SELECT * FROM usable",
                "SELECT coalesce(fn_stock_measurement_usable(?,?,CAST(? AS uuid)),true)",
                "SELECT fn_stock_measurement_usable(?,?,CAST(? AS uuid)); SELECT id FROM stock_balances")) {
            assertFalse(label(sql).startsWith("measurement."), sql);
        }
    }

    @Test void onlyTheStandaloneSourceOrderDifferenceProjectionGetsItsOwnLabel() {
        assertEquals("finance.source_order_difference", label(
                "SELECT item.id, ((item.received_qty)-(item.returned_qty)-(item.qty)), item.unit_id"
                + " FROM subcontract_order_items item"
                + " JOIN subcontract_orders source_order ON source_order.id=item.order_id"
                + " WHERE item.id IN (?, ?) AND NOT item.is_deleted AND NOT source_order.is_deleted AND (1=1)"));
        assertEquals("finance.source_order_difference", label(
                "SELECT item.id, ((item.received_qty)-(item.returned_qty)-(item.qty)), item.unit_id"
                + " FROM purchase_order_items item"
                + " JOIN purchase_orders source_order ON source_order.id=item.order_id"
                + " WHERE item.id IN (?) AND NOT item.is_deleted AND NOT source_order.is_deleted"
                + " AND (source_order.maker_id IN (?))"));
        for (String sql : List.of(
                // The report's LATERAL projection keeps its ordinary read label.
                "SELECT receipt.id FROM purchase_receipts receipt"
                + " LEFT JOIN LATERAL (SELECT ((source_item.received_qty)-(source_item.returned_qty)-(source_item.qty)) AS qty"
                + " FROM purchase_order_items source_item"
                + " JOIN purchase_orders source_order ON source_order.id=source_item.order_id"
                + " WHERE source_item.id=i.order_item_id) source_order_difference ON TRUE",
                // Same tables, but not the difference projection shape.
                "SELECT item.id FROM subcontract_order_items item"
                + " JOIN subcontract_orders source_order ON source_order.id=item.order_id WHERE item.id IN (?)",
                "SELECT item.id, item.qty, item.unit_id FROM subcontract_order_items item"
                + " JOIN subcontract_orders source_order ON source_order.id=item.order_id WHERE item.id IN (?)",
                // Extra output columns mean it is no longer the standalone projection.
                "SELECT item.id, ((item.received_qty)-(item.returned_qty)-(item.qty)), item.unit_id, item.qty"
                + " FROM subcontract_order_items item"
                + " JOIN subcontract_orders source_order ON source_order.id=item.order_id WHERE item.id IN (?)")) {
            assertEquals("read.other", label(sql), sql);
        }
    }

    @Test void commandAndReplayFromTheSameTestKeepBothRawTraceCounts(@TempDir Path directory) throws Exception {
        String property = "uten.jdbc.measurement.trace-directory";
        String previous = System.getProperty(property);
        System.setProperty(property, directory.toString());
        try {
            var command = ProductionJdbcMeasurement.begin();
            command.logicalStatements = 3;
            ProductionJdbcMeasurement.end();
            var replay = ProductionJdbcMeasurement.begin();
            replay.logicalStatements = 1;
            ProductionJdbcMeasurement.end();
            try (var files = Files.list(directory)) {
                var counts = files.map(path -> {
                    try { return new com.fasterxml.jackson.databind.ObjectMapper().readTree(path.toFile())
                            .path("logicalStatements").asLong(); }
                    catch (java.io.IOException failure) { throw new java.io.UncheckedIOException(failure); }
                }).sorted().toList();
                assertEquals(List.of(1L, 3L), counts, "the replay must not erase the original command trace");
            }
        } finally {
            ProductionJdbcMeasurement.end();
            if (previous == null) System.clearProperty(property); else System.setProperty(property, previous);
        }
    }

    private static String label(String sql) { return ProductionJdbcMeasurement.queryLabel(sql); }
}
