package com.uten.imp.common.export;

import org.apache.poi.ss.usermodel.DataFormatter;
import org.apache.poi.ss.usermodel.CellType;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayInputStream;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class XlsxUnitDisplayTest {
    @Test void currencyAndQuantityUnitsAreDisplayedWithoutChangingStoredNumbers() throws Exception {
        byte[] bytes = new XlsxExportService().build(List.of(
                new ExportColumn("original", "原币金额", "money", null, null, "currency"),
                new ExportColumn("local", "人民币金额", "money", null, "元", null),
                new ExportColumn("qty", "数量", "qty", null, null, "unit")), List.of(Map.of(
                "original", new BigDecimal("37.28"), "local", new BigDecimal("260.96"),
                "qty", new BigDecimal("0.0001"), "currency", "美金", "unit", "个")));
        try (var workbook = new XSSFWorkbook(new ByteArrayInputStream(bytes))) {
            var row = workbook.getSheetAt(0).getRow(1);
            DataFormatter formatter = new DataFormatter(java.util.Locale.CHINA);
            assertThat(row.getCell(0).getCellType()).isEqualTo(CellType.NUMERIC);
            assertThat(row.getCell(0).getNumericCellValue()).isEqualTo(37.28);
            assertThat(formatter.formatCellValue(row.getCell(0))).isEqualTo("37.28 美金");
            assertThat(formatter.formatCellValue(row.getCell(1))).isEqualTo("260.96 元");
            assertThat(formatter.formatCellValue(row.getCell(2))).isEqualTo("0.0001 个");
        }
    }

    @Test void highPrecisionAndUnknownValuesRetainTheirOriginalCellValue() throws Exception {
        String exact = "999999999999.000001";
        byte[] bytes = new XlsxExportService().build(List.of(
                new ExportColumn("price", "价格", "money", null, "美金", null)),
                List.of(Map.of("price", new BigDecimal(exact)), Map.of("price", "***")));
        try (var workbook = new XSSFWorkbook(new ByteArrayInputStream(bytes))) {
            assertThat(workbook.getSheetAt(0).getRow(1).getCell(0).getStringCellValue()).isEqualTo(exact);
            assertThat(workbook.getSheetAt(0).getRow(1).getCell(0).getCellStyle().getDataFormatString())
                    .contains("美金");
            assertThat(workbook.getSheetAt(0).getRow(2).getCell(0).getStringCellValue()).isEqualTo("***");
        }
    }
}
