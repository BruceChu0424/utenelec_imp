package com.uten.imp.common.export;

import org.apache.pdfbox.Loader;
import org.apache.pdfbox.pdmodel.encryption.InvalidPasswordException;
import org.apache.pdfbox.rendering.PDFRenderer;
import org.apache.pdfbox.text.PDFTextStripper;
import org.apache.poi.ss.usermodel.CellType;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import java.io.ByteArrayInputStream;
import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

class CostDocumentExportTest {
    @Test void legalLongExactAmountsAreNeverReplacedWithEllipses() throws Exception {
        String exact = "9".repeat(40) + "." + "1".repeat(30);
        BigDecimal amount = com.uten.imp.common.util.FinancialExactAmount.book(new BigDecimal(exact), "金额");
        var columns = new ArrayList<ExportColumn>(); columns.add(new ExportColumn("name", "名称", ExportColumn.TEXT));
        var row = new LinkedHashMap<String,Object>(); row.put("name", "精确金额");
        for (int i=0;i<5;i++) { columns.add(new ExportColumn("amount"+i,"金额"+i,ExportColumn.QTY)); row.put("amount"+i,amount); }
        var document = new ExportDocument("完整精度", List.of("禁止截断金额"), List.of(new ExportDocument.Section("金额",columns,List.of(row))));
        try(var pdf=Loader.loadPDF(new TabularPdfExportService().build(document,null))) {
            String text=new PDFTextStripper().getText(pdf);
            assertThat(text).contains(exact).doesNotContain("...");
        }
    }
    @Test void excelKeepsMultipleSheetsUnknownsExactSmallValuesAndLiteralCells() throws Exception {
        var bytes = new XlsxExportService().buildDocument(document(2));
        try (var wb = new XSSFWorkbook(new ByteArrayInputStream(bytes))) {
            assertThat(wb.getNumberOfSheets()).isEqualTo(3);
            var sheet = wb.getSheet("物料明细");
            assertThat(sheet.getRow(1).getCell(0).getStringCellValue()).isEqualTo("80N 一开按钮");
            assertThat(sheet.getRow(1).getCell(1).getNumericCellValue()).isEqualTo(.00007);
            assertThat(sheet.getRow(1).getCell(1).getCellStyle().getDataFormatString()).isEqualTo("General");
            assertThat(sheet.getRow(1).getCell(2).getCellType()).isEqualTo(CellType.STRING);
            assertThat(sheet.getRow(1).getCell(2).getStringCellValue()).isEqualTo("1234567890123456.00000000007");
            assertThat(sheet.getRow(1).getCell(3).getCellType()).isEqualTo(CellType.STRING);
            assertThat(sheet.getRow(1).getCell(3).getStringCellValue()).startsWith("=HYPERLINK");
            assertThat(sheet.getRow(1).getCell(4).getCellType()).isEqualTo(CellType.BLANK);
            assertThat(sheet.getPaneInformation().isFreezePane()).isTrue();
        }
    }

    @Test void pdfHasEmbeddedReadableChinesePaginationAndRealPasswordProtection() throws Exception {
        var service = new TabularPdfExportService();
        byte[] bytes = service.build(document(48), null);
        try (var pdf = Loader.loadPDF(bytes)) {
            assertThat(pdf.getNumberOfPages()).isGreaterThanOrEqualTo(4);
            String text = new PDFTextStripper().getText(pdf);
            assertThat(text).contains("货品成本单", "80N 一开按钮", "0.00007", "版本与口径", "第 1 页", "V-test");
            assertThat(pdf.getPage(0).getResources().getFont(pdf.getPage(0).getResources().getFontNames().iterator().next()).isEmbedded()).isTrue();
            String qa = System.getProperty("uten.cost.export.qa");
            if (qa != null && !qa.isBlank()) {
                Path dir = Path.of(qa).toAbsolutePath(); Files.createDirectories(dir);
                Files.write(dir.resolve("cost-export-sample.pdf"), bytes);
                var renderer = new PDFRenderer(pdf);
                for (int page : List.of(0, 1, pdf.getNumberOfPages() - 1))
                    javax.imageio.ImageIO.write(renderer.renderImageWithDPI(page, 110), "png", dir.resolve("cost-export-page-" + page + ".png").toFile());
            }
        }
        byte[] locked = service.build(document(1), "test-only-export-password");
        assertThatThrownBy(() -> Loader.loadPDF(locked)).isInstanceOf(InvalidPasswordException.class);
        try (var pdf = Loader.loadPDF(locked, "test-only-export-password")) {
            assertThat(new PDFTextStripper().getText(pdf)).contains("80N 一开按钮");
        }
    }

    private static ExportDocument document(int size) {
        var rows = new ArrayList<Map<String, Object>>();
        for (int i = 0; i < size; i++) {
            var row = new LinkedHashMap<String, Object>();
            row.put("name", "80N 一开按钮"); row.put("qty", new BigDecimal("0.00007"));
            row.put("amount", new BigDecimal("1234567890123456.00000000007"));
            row.put("note", "=HYPERLINK(\"https://invalid.example\")"); row.put("unknown", null); rows.add(row);
        }
        return new ExportDocument("货品成本单", List.of("版本: V-test", "口径: 本币，成本测算", "状态: 草稿"), List.of(
                new ExportDocument.Section("物料明细", List.of(new ExportColumn("name", "货品名称", ExportColumn.TEXT),
                        new ExportColumn("qty", "采用量", ExportColumn.QTY), new ExportColumn("amount", "精确金额", ExportColumn.QTY),
                        new ExportColumn("note", "来源", ExportColumn.TEXT), new ExportColumn("unknown", "待核金额", ExportColumn.QTY)), rows),
                new ExportDocument.Section("费用汇总", List.of(new ExportColumn("name", "费用名称", ExportColumn.TEXT),
                        new ExportColumn("amount", "金额", ExportColumn.QTY)), List.of(Map.of("name", "安装人工", "amount", new BigDecimal("0.725"))))));
    }
}
