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
        assertDecimal("0.3", number("0.30000000000000004", false, "qty", "General"));
    }

    @Test void explicitTextAndRealExcessScaleStillRejectWithoutRounding() {
        assertThrows(NumberFormatException.class, () -> number("35.299999999999997", true, "qty", "General"));
        assertThrows(NumberFormatException.class, () -> number("0.000001", false, "qty", "0.00"));
        assertThrows(NumberFormatException.class, () -> number("0.1234567", false, "basisOutputQty", "0.00"));
    }

    @Test void explicitValidFractionAndNativeTailUseTheSameBusinessQuantity() throws Exception {
        assertDecimal("0.03125", number("0.03125", true, "qty", "General"));
        assertDecimal("35.3", number("35.299999999999997", false, "qty", "General"));
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
