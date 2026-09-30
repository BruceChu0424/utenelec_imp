package com.uten.imp.common.export;

import org.apache.poi.ss.usermodel.CellType;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import java.io.ByteArrayInputStream;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;

class XlsxTableProjectionPrecisionTest {
    @Test void generatedWorkbookKeepsSelectedOrderWidthExactDecimalsAndLiteralText() throws Exception {
        var bytes = new XlsxExportService().build(List.of(
            new ExportColumn("reference", "客户编号", ExportColumn.TEXT, 210d),
            new ExportColumn("qty", "用量", ExportColumn.NUMBER, 140d),
            new ExportColumn("amount", "精确金额", ExportColumn.MONEY),
            new ExportColumn("note", "备注", ExportColumn.TEXT)),
            List.of(Map.of("reference", "000017", "qty", new BigDecimal("0.00000003125"),
                "amount", new BigDecimal("1234567890123456.12"), "note", "=HYPERLINK(\"https://invalid.example\")", "hidden", "omit")));
        try (var book = new XSSFWorkbook(new ByteArrayInputStream(bytes))) {
            var sheet = book.getSheetAt(0);
            assertThat(sheet.getRow(0).getLastCellNum()).isEqualTo((short)4);
            assertThat(sheet.getRow(0).getCell(0).getStringCellValue()).isEqualTo("客户编号");
            assertThat(sheet.getColumnWidth(0)).isEqualTo(30*256);
            var row = sheet.getRow(1);
            assertThat(row.getCell(0).getStringCellValue()).isEqualTo("000017");
            assertThat(row.getCell(1).getNumericCellValue()).isEqualTo(0.00000003125);
            assertThat(row.getCell(1).getCellStyle().getDataFormatString()).isEqualTo("General");
            assertThat(row.getCell(2).getStringCellValue()).isEqualTo("1234567890123456.12");
            assertThat(row.getCell(3).getCellType()).isEqualTo(CellType.STRING);
            assertThat(row.getCell(3).getCellStyle().getDataFormatString()).isEqualTo("@");
        }
    }
}
