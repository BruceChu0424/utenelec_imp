package com.uten.imp.features.master.goods.importing;

import org.apache.poi.ss.usermodel.DataFormatter;
import org.apache.poi.xssf.usermodel.XSSFCell;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.math.BigDecimal;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class GoodsBomImportNumericPrecisionTest {
    @Test void quantityAndBasisKeepTheirOwnSupportedScaleDespiteTheDisplayFormat() throws Exception {
        assertDecimal("0.03125", number("0.03125", false, "qty", "0.00"));
        assertDecimal("0.123456", number("0.123456", false, "basisOutputQty", "0.00"));
        // 2026-11-04 起按 0aaffa3aa 精确原数契约：原生二进制尾差不再折算到 Excel 15 位精度，按存储值原样保留。
        assertDecimal("0.30000000000000004", number("0.30000000000000004", false, "qty", "General"));
        // 每列不再有 5/6 位小数上限；24 位有效小数内按存储值全精度接受。
        assertDecimal("0.000001", number("0.000001", false, "qty", "0.00"));
        assertDecimal("0.1234567", number("0.1234567", false, "basisOutputQty", "0.00"));
    }

    @Test void explicitTextAndRealExcessScaleStillRejectWithoutRounding() throws Exception {
        // 2026-11-04 起按 0aaffa3aa 契约：上限放宽到 40 位整数、24 位有效小数，且不再静默舍入。
        // 显式文本与原生数值超出 24 位有效小数同样整行报错，不做任何就近取整。
        assertThrows(NumberFormatException.class, () -> number("0.1234567890123456789012345", true, "qty", "General"));
        assertThrows(NumberFormatException.class, () -> number("0.1234567890123456789012345", false, "qty", "General"));
        assertThrows(NumberFormatException.class, () -> number("1e999999999", true, "qty", "General"));
    }

    @Test void explicitValidFractionAndNativeTailUseTheSameBusinessQuantity() throws Exception {
        assertDecimal("0.03125", number("0.03125", true, "qty", "General"));
        // 2026-11-04 起按 0aaffa3aa 契约：文本与原生同一存储值得到同一精确业务数量，不再折算尾差。
        assertDecimal("35.299999999999997", number("35.299999999999997", true, "qty", "General"));
        assertDecimal("35.299999999999997", number("35.299999999999997", false, "qty", "General"));
    }

    @Test void validEighteenDigitNativeQuantitiesKeepEverySourceDigit() throws Exception {
        assertDecimal("1234567890123.12345", number("1234567890123.12345", false, "qty", "#,##0.00"));
        assertDecimal("123456789012.123456", number("123456789012.123456", false, "basisOutputQty", "#,##0.00"));
    }

    private static BigDecimal number(String raw, boolean text, String key, String format) throws Exception {
        byte[] bytes;
        try (var source = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            XSSFCell cell = source.createSheet("配件").createRow(0).createCell(0);
            if (text) cell.setCellValue(raw);
            else { cell.setCellValue(0); cell.getCTCell().setV(raw); }
            var style = source.createCellStyle();
            style.setDataFormat(source.createDataFormat().getFormat(format));
            cell.setCellStyle(style);
            source.write(out); bytes = out.toByteArray();
        }
        try (var reopened = new XSSFWorkbook(new ByteArrayInputStream(bytes))) {
            return org.springframework.test.util.ReflectionTestUtils.invokeMethod(GoodsBomImportService.class,
                    "number", new DataFormatter(), reopened.getSheetAt(0).getRow(0), Map.of(key, 0), key);
        }
    }

    private static void assertDecimal(String expected, BigDecimal actual) {
        assertEquals(0, new BigDecimal(expected).compareTo(actual));
    }
}
