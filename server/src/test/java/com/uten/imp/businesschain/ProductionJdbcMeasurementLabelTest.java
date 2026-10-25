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
