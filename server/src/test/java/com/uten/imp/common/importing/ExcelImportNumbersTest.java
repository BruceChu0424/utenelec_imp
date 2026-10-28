package com.uten.imp.common.importing;

import org.apache.poi.ss.usermodel.CellStyle;
import org.apache.poi.xssf.usermodel.XSSFCell;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.math.BigDecimal;

import static org.junit.jupiter.api.Assertions.assertEquals;

class ExcelImportNumbersTest {
    @Test void nativeFloatingTailsWithinOneUlpCanReturnToTheSupportedDecimal() throws Exception {
        assertEquals("35.3", numeric("35.299999999999997", 4, "General", false));
        assertEquals("0.3", numeric("0.30000000000000004", 4, "General", false));
    }

    @Test void cleanNativeValueIgnoresTheTwoDecimalDisplayMask() throws Exception {
        assertEquals("35.1", numeric("35.1", 4, "#,##0.00", false));
        assertEquals("0.03125", numeric("0.03125", 5, "0.00", false));
        assertEquals("0.123456", numeric("0.123456", 6, "0.00", false));
    }

    @Test void alreadySupportedLargeDecimalNeverCrossesADoubleBoundary() throws Exception {
        String exact = "99999999999999.9999";
        assertEquals(exact, numeric(exact, 4, "#,##0.00", false));
        assertEquals("35.3000", numeric("35.3000", 4, "General", false));
    }

    @Test void legitimateOverScaleDecimalsRemainAvailableForCallerRejection() throws Exception {
        assertEquals("0.123456", numeric("0.123456", 4, "General", false));
        assertEquals("0.000001", numeric("0.000001", 5, "General", false));
    }

    @Test void fifteenDigitSimilarityAloneDoesNotPermitSeveralUlpsOfRounding() throws Exception {
        assertEquals("35.29999999999997", numeric("35.29999999999997", 4, "General", false));
    }

    @Test void cachedNumericFormulaUsesItsCacheWithoutEvaluation() throws Exception {
        assertEquals("35.3", numeric("35.299999999999997", 4, "General", true));
    }

    @Test void exactlyOneBinaryUlpIsIncludedWithoutRoundingItsDecimalBoundary() throws Exception {
        BigDecimal exactUlp=new BigDecimal(Math.ulp(1.0));
        assertEquals("1",numeric(BigDecimal.ONE.add(exactUlp).toPlainString(),4,"General",false));
    }

    @Test void bothSignsAndDirectionsKeepTheExactUlpAndItsEpsilonNeighboursDistinct() throws Exception {
        BigDecimal epsilon=new BigDecimal("1e-32");
        for(String sign:new String[]{"35.3","-35.3"})for(int direction:new int[]{-1,1}) {
            BigDecimal candidate=new BigDecimal(sign);
            BigDecimal exactUlp=new BigDecimal(Math.ulp(candidate.doubleValue()));
            BigDecimal multiplier=BigDecimal.valueOf(direction);
            String inside=candidate.add(exactUlp.subtract(epsilon).multiply(multiplier)).toPlainString();
            String boundary=candidate.add(exactUlp.multiply(multiplier)).toPlainString();
            String outside=candidate.add(exactUlp.add(epsilon).multiply(multiplier)).toPlainString();
            assertEquals(sign,numeric(inside,4,"General",false));
            assertEquals(sign,numeric(boundary,4,"General",false));
            assertEquals(outside,numeric(outside,4,"General",false));
        }
    }

    private static String numeric(String raw, int scale, String format, boolean formula) throws Exception {
        byte[] bytes;
        try (var source = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            XSSFCell cell = source.createSheet("数值边界").createRow(0).createCell(0);
            cell.setCellValue(0);
            if (formula) cell.setCellFormula("1+1");
            cell.getCTCell().setV(raw);
            CellStyle style = source.createCellStyle();
            style.setDataFormat(source.createDataFormat().getFormat(format));
            cell.setCellStyle(style);
            source.write(out); bytes = out.toByteArray();
        }
        try (var reopened = new XSSFWorkbook(new ByteArrayInputStream(bytes))) {
            XSSFCell cell=reopened.getSheetAt(0).getRow(0).getCell(0);
            String original=cell.getRawValue();
            String result=ExcelImportNumbers.numericText(cell, scale);
            assertEquals(original,cell.getRawValue(),"numeric ingestion must not rewrite original OOXML evidence");
            return result;
        }
    }
}
