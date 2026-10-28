package com.uten.imp.features.master.goods.importing;

import org.apache.poi.ss.usermodel.Row;
import org.apache.poi.xssf.usermodel.XSSFCell;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;
import org.springframework.test.util.ReflectionTestUtils;

import java.io.ByteArrayOutputStream;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class GoodsImportNumericPrecisionTest {
    private final GoodsImportService importer = new GoodsImportService(
            null, null, null, null, null, null, null, null, null, null, null);

    @Test void nativePriceAndPurchaseQuantitiesRemoveOnlyRepresentationalTails() throws Exception {
        var parsed = parse(workbook(row -> {
            rawNumeric(row, 3, "35.299999999999997", "#,##0.00");
            rawNumeric(row, 4, "0.30000000000000004", "General");
            rawNumeric(row, 5, "35.299999999999997", "General");
        }), Map.of());

        assertTrue(errors(parsed).isEmpty(), errors(parsed).toString());
        Object row = rows(parsed).getFirst();
        assertDecimal("35.3", row, "price");
        assertDecimal("0.3", row, "minOrderQty");
        assertDecimal("35.3", row, "orderMultipleQty");
        assertEquals("35.3", cells(row).get("price"));
    }

    @Test void cleanNumericCellWithTheActualFilesTwoDecimalFormatStaysExact() throws Exception {
        var parsed = parse(workbook(row -> rawNumeric(row, 3, "35.1", "#,##0.00")), Map.of());

        assertTrue(errors(parsed).isEmpty(), errors(parsed).toString());
        assertDecimal("35.1", rows(parsed).getFirst(), "price");
        assertEquals("35.1", cells(rows(parsed).getFirst()).get("price"));
    }

    @Test void supportedScaleFourValueAboveJavascriptSafeFractionalPrecisionIsPreserved() throws Exception {
        var parsed = parse(workbook(row -> rawNumeric(row, 3, "99999999999999.9999", "#,##0.00")), Map.of());

        assertTrue(errors(parsed).isEmpty(), errors(parsed).toString());
        assertDecimal("99999999999999.9999", rows(parsed).getFirst(), "price");
        assertEquals("99999999999999.9999", cells(rows(parsed).getFirst()).get("price"));
    }

    @Test void explicitTextAndLegitimateNumericFractionsRemainVisibleErrors() throws Exception {
        for (String text : List.of("35.299999999999997", "0.123456")) {
            var parsed = parse(workbook(row -> row.createCell(3).setCellValue(text)), Map.of());
            assertPriceError(parsed);
            assertEquals(text, cells(rows(parsed).getFirst()).get("price"));
        }
        assertPriceError(parse(workbook(row -> rawNumeric(row, 3, "0.123456", "0.00")), Map.of()));
        assertPriceError(parse(workbook(row -> rawNumeric(row, 3, "35.29999999999997", "0.00")), Map.of()));
    }

    @Test void editedNumericTextIsNeverTreatedAsANativeFloatingPointArtifact() throws Exception {
        byte[] file = workbook(row -> rawNumeric(row, 3, "35.299999999999997", "General"));
        var rejected = parse(file, Map.of(2, Map.of("price", "35.299999999999997")));
        assertPriceError(rejected);
        assertEquals("35.299999999999997", cells(rows(rejected).getFirst()).get("price"));
        var accepted = parse(file, Map.of(2, Map.of("price", "35.3")));
        assertTrue(errors(accepted).isEmpty());
        assertDecimal("35.3", rows(accepted).getFirst(), "price");
    }

    @Test @Timeout(5) void exponentAndStorageBoundsStillRejectInsteadOfUnderflowingOrRoundingToZero() throws Exception {
        for (String raw : List.of("1E999999999", "1E-999999999", "0E-999999999", "0E999999999", "100000000000000")) {
            assertPriceError(parse(workbook(row -> rawNumeric(row, 3, raw, "General")), Map.of()));
            assertPriceError(parse(workbook(row -> row.createCell(3).setCellValue(raw)), Map.of()));
            assertPriceError(parse(workbook(row -> row.createCell(3).setCellValue("1")),
                    Map.of(2, Map.of("price", raw))));
        }
    }

    @Test void numericCodeKeepsItsIdentifierDisplayMask() throws Exception {
        var parsed = parse(workbook(row -> {
            rawNumeric(row, 0, "7", "000000");
            rawNumeric(row, 3, "35.1", "#,##0.00");
        }), Map.of());

        assertTrue(errors(parsed).isEmpty());
        assertEquals("000007", ReflectionTestUtils.getField(rows(parsed).getFirst(), "code"));
    }

    private Object parse(byte[] file, Map<Integer, Map<String, String>> corrections) {
        return ReflectionTestUtils.invokeMethod(importer, "parse", file, corrections);
    }

    @SuppressWarnings("unchecked")
    private static List<Object> rows(Object parsed) { return (List<Object>) ReflectionTestUtils.getField(parsed, "rows"); }
    @SuppressWarnings("unchecked")
    private static List<GoodsImportError> errors(Object parsed) { return (List<GoodsImportError>) ReflectionTestUtils.getField(parsed, "headerErrors"); }
    @SuppressWarnings("unchecked")
    private static Map<String, String> cells(Object row) { return (Map<String, String>) ReflectionTestUtils.getField(row, "cells"); }

    private static void assertPriceError(Object parsed) {
        assertTrue(errors(parsed).stream().anyMatch(error -> "价格".equals(error.column())), errors(parsed).toString());
        assertNull(ReflectionTestUtils.getField(rows(parsed).getFirst(), "price"));
    }

    private static void assertDecimal(String expected, Object row, String field) {
        assertEquals(0, new BigDecimal(expected).compareTo((BigDecimal) ReflectionTestUtils.getField(row, field)));
    }

    private static byte[] workbook(Consumer<Row> configure) throws Exception {
        try (var book = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            var sheet = book.createSheet("货品");
            String[] titles = {"编号", "货品名称", "类别", "价格", "最小起订量", "订货倍数"};
            var header = sheet.createRow(0);
            for (int column = 0; column < titles.length; column++) header.createCell(column).setCellValue(titles[column]);
            var row = sheet.createRow(1);
            row.createCell(0).setCellValue("NUMERIC-BOUNDARY");
            row.createCell(1).setCellValue("数值边界货品");
            row.createCell(2).setCellValue("成品");
            configure.accept(row);
            book.write(out); return out.toByteArray();
        }
    }

    private static void rawNumeric(Row row, int column, String raw, String format) {
        XSSFCell cell = (XSSFCell) row.createCell(column);
        cell.setCellValue(0);
        cell.getCTCell().setV(raw);
        var workbook = row.getSheet().getWorkbook();
        var style = workbook.createCellStyle();
        style.setDataFormat(workbook.createDataFormat().getFormat(format));
        cell.setCellStyle(style);
    }
}
