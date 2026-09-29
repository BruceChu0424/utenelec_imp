package com.uten.imp.common.files.document;

import com.uten.imp.common.files.document.DocumentGrid.CellKind;
import com.uten.imp.common.files.document.DocumentGrid.Sheet;
import com.uten.imp.common.web.ApiException;
import org.apache.poi.hssf.usermodel.HSSFWorkbook;
import org.apache.poi.poifs.filesystem.POIFSFileSystem;
import org.apache.poi.ss.usermodel.Cell;
import org.apache.poi.ss.usermodel.CellStyle;
import org.apache.poi.ss.usermodel.Row;
import org.apache.poi.ss.usermodel.Workbook;
import org.apache.poi.ss.util.CellRangeAddress;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.math.BigDecimal;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.util.function.Consumer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class SpreadsheetGridReaderTest {

    private static byte[] write(Workbook wb) throws IOException {
        try (wb; ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            wb.write(out);
            return out.toByteArray();
        }
    }

    private static byte[] xlsx(Consumer<XSSFWorkbook> build) throws IOException {
        XSSFWorkbook wb = new XSSFWorkbook();
        build.accept(wb);
        return write(wb);
    }

    @Test
    void readsCachedFormulaResultsButNeverTheFormulaText() throws IOException {
        byte[] bytes = xlsx(wb -> {
            var sheet = wb.createSheet("Quote");
            Row row = sheet.createRow(0);
            row.createCell(0).setCellValue(3);
            row.createCell(1).setCellValue(7.5);
            row.createCell(2).setCellFormula("A1*B1");
            row.createCell(3).setCellFormula("\"GK\"&\"12\"");
            wb.getCreationHelper().createFormulaEvaluator().evaluateAll();
        });
        Sheet sheet = SpreadsheetGridReader.read(bytes, DocumentKind.XLSX).sheets().getFirst();
        DocumentGrid.Cell product = sheet.row(0).cell(2);
        assertThat(product.kind()).isEqualTo(CellKind.NUMBER);
        assertThat(product.number()).isEqualByComparingTo("22.5");
        assertThat(product.text()).isEqualTo("22.5");
        assertThat(sheet.text(0, 3)).isEqualTo("GK12");
        assertThat(sheet.rows().getFirst().joinedText()).doesNotContain("A1*B1").doesNotContain("&");
    }

    @Test
    void numbersAreExactAndTrimmedToExcelPrecision() throws IOException {
        byte[] bytes = xlsx(wb -> {
            Row row = wb.createSheet("S").createRow(0);
            row.createCell(0).setCellValue(0.1 + 0.2);
            row.createCell(1).setCellValue(1800);
            row.createCell(2).setCellValue(1.61568);
        });
        Sheet sheet = SpreadsheetGridReader.read(bytes, DocumentKind.XLSX).sheets().getFirst();
        assertThat(sheet.text(0, 0)).isEqualTo("0.3");
        assertThat(sheet.text(0, 1)).isEqualTo("1800");
        assertThat(sheet.row(0).cell(2).number()).isEqualByComparingTo(new BigDecimal("1.61568"));
    }

    @Test
    void mergedHeaderMultiLineCellsAndStyledEmptyColumnsAreHandled() throws IOException {
        byte[] bytes = xlsx(wb -> {
            var sheet = wb.createSheet("PI");
            CellStyle bordered = wb.createCellStyle();
            bordered.setBorderBottom(org.apache.poi.ss.usermodel.BorderStyle.THIN);
            Row title = sheet.createRow(0);
            title.createCell(0).setCellValue("Proforma Invoice");
            sheet.addMergedRegion(CellRangeAddress.valueOf("A1:H1"));
            Row header = sheet.createRow(2);
            header.createCell(0).setCellValue("Part No.\n零配件编号");
            header.createCell(1).setCellValue("order qty(pcs)");
            for (int c = 2; c < 255; c++) {
                header.createCell(c).setCellStyle(bordered);
            }
        });
        Sheet sheet = SpreadsheetGridReader.read(bytes, DocumentKind.XLSX).sheets().getFirst();
        assertThat(sheet.text(2, 0)).isEqualTo("Part No.\n零配件编号");
        assertThat(sheet.maxColumn()).isEqualTo(1);
        assertThat(sheet.mergeAt(0, 5)).isNotNull();
        assertThat(sheet.mergeAt(0, 5).firstCol()).isZero();
        assertThat(sheet.row(0).cells()).hasSize(1);
    }

    @Test
    void hiddenRowsColumnsAndSheetsAreSkipped() throws IOException {
        byte[] bytes = xlsx(wb -> {
            var visible = wb.createSheet("Visible");
            Row r0 = visible.createRow(0);
            r0.createCell(0).setCellValue("keep");
            r0.createCell(3).setCellValue("hidden column");
            visible.setColumnHidden(3, true);
            Row r1 = visible.createRow(1);
            r1.createCell(0).setCellValue("hidden row");
            r1.setZeroHeight(true);
            wb.createSheet("Secret").createRow(0).createCell(0).setCellValue("secret");
            wb.setSheetHidden(1, true);
        });
        DocumentGrid grid = SpreadsheetGridReader.read(bytes, DocumentKind.XLSX);
        assertThat(grid.sheets()).hasSize(1);
        Sheet sheet = grid.sheets().getFirst();
        assertThat(sheet.rows()).hasSize(1);
        assertThat(sheet.row(0).cells()).hasSize(1);
        assertThat(sheet.skippedHiddenRows()).isEqualTo(1);
    }

    @Test
    void datesBecomeIsoText() throws IOException {
        byte[] bytes = xlsx(wb -> {
            CellStyle date = wb.createCellStyle();
            date.setDataFormat(wb.getCreationHelper().createDataFormat().getFormat("yyyy-mm-dd"));
            Cell c = wb.createSheet("S").createRow(0).createCell(0);
            c.setCellValue(LocalDate.of(2026, 7, 6));
            c.setCellStyle(date);
        });
        DocumentGrid.Cell cell = SpreadsheetGridReader.read(bytes, DocumentKind.XLSX).sheets().getFirst().row(0).cell(0);
        assertThat(cell.kind()).isEqualTo(CellKind.DATE);
        assertThat(cell.text()).isEqualTo("2026-07-06");
    }

    @Test
    void readsLegacyXls() throws IOException {
        HSSFWorkbook wb = new HSSFWorkbook();
        var sheet = wb.createSheet("旧表");
        Row row = sheet.createRow(4);
        row.createCell(0).setCellValue("GZ23/D");
        row.createCell(1).setCellValue(1800);
        row.createCell(2).setCellFormula("B5*2");
        wb.getCreationHelper().createFormulaEvaluator().evaluateAll();
        sheet.addMergedRegion(CellRangeAddress.valueOf("A1:C1"));
        Row hidden = sheet.createRow(5);
        hidden.createCell(0).setCellValue("x");
        hidden.setZeroHeight(true);
        byte[] bytes = write(wb);
        Sheet read = SpreadsheetGridReader.read(bytes, DocumentKind.XLS).sheets().getFirst();
        assertThat(read.name()).isEqualTo("旧表");
        assertThat(read.text(4, 0)).isEqualTo("GZ23/D");
        assertThat(read.row(4).cell(2).number()).isEqualByComparingTo("3600");
        assertThat(read.row(5)).isNull();
        assertThat(read.merges()).hasSize(1);
    }

    @Test
    void xlsWithMacrosOrEncryptionIsRejected() throws IOException {
        POIFSFileSystem macro = new POIFSFileSystem();
        macro.getRoot().createDirectory("_VBA_PROJECT_CUR");
        macro.createDocument(new ByteArrayInputStream(new byte[16]), "Workbook");
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        macro.writeFilesystem(out);
        assertThatThrownBy(() -> SpreadsheetGridReader.read(out.toByteArray(), DocumentKind.XLS))
                .isInstanceOf(ApiException.class).hasMessageContaining("宏");

        POIFSFileSystem encrypted = new POIFSFileSystem();
        encrypted.createDocument(new ByteArrayInputStream(new byte[16]), "EncryptedPackage");
        ByteArrayOutputStream out2 = new ByteArrayOutputStream();
        encrypted.writeFilesystem(out2);
        assertThatThrownBy(() -> SpreadsheetGridReader.read(out2.toByteArray(), DocumentKind.XLS))
                .isInstanceOf(ApiException.class).hasMessageContaining("密码");
    }

    @Test
    void xlsxWithMacroOrExternalLinkIsRejectedButImagesAreFine() throws IOException {
        byte[] plain = xlsx(wb -> wb.createSheet("S").createRow(0).createCell(0).setCellValue("ok"));
        assertThatThrownBy(() -> SpreadsheetGridReader.read(
                DocumentReaderTestSupport.withEntry(plain, "xl/vbaProject.bin", new byte[64]), DocumentKind.XLSX))
                .isInstanceOf(ApiException.class).hasMessageContaining("宏");
        assertThatThrownBy(() -> SpreadsheetGridReader.read(
                DocumentReaderTestSupport.withEntry(plain, "xl/externalLinks/externalLink1.xml", "<x/>".getBytes()),
                DocumentKind.XLSX)).isInstanceOf(ApiException.class);
        byte[] withImage = xlsx(wb -> {
            var sheet = wb.createSheet("S");
            sheet.createRow(0).createCell(0).setCellValue("ok");
            byte[] png = {(byte) 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 0, 1, 0, 0, 0, 1};
            int picture = wb.addPicture(png, Workbook.PICTURE_TYPE_PNG);
            var anchor = wb.getCreationHelper().createClientAnchor();
            anchor.setCol1(3);
            anchor.setRow1(3);
            sheet.createDrawingPatriarch().createPicture(anchor, picture);
        });
        assertThat(DocumentReaderTestSupport.unzip(withImage).keySet()).anyMatch(n -> n.startsWith("xl/media/"));
        assertThat(SpreadsheetGridReader.read(withImage, DocumentKind.XLSX).sheets().getFirst().text(0, 0)).isEqualTo("ok");
    }

    @Test
    void rowLimitTruncatesInsteadOfReadingForever() throws IOException {
        byte[] bytes = xlsx(wb -> {
            var sheet = wb.createSheet("Big");
            for (int r = 0; r < SpreadsheetGridReader.MAX_ROWS_PER_SHEET + 20; r++) {
                sheet.createRow(r).createCell(0).setCellValue(r);
            }
        });
        Sheet sheet = SpreadsheetGridReader.read(bytes, DocumentKind.XLSX).sheets().getFirst();
        assertThat(sheet.truncated()).isTrue();
        assertThat(sheet.rows()).hasSize(SpreadsheetGridReader.MAX_ROWS_PER_SHEET);
    }

    @Test
    void csvGbkSemicolonsAndQuotedNewlines() {
        String text = "序号;型号;品名;数量\n1;GZ23/D;\"两开多功能\n三极插座\";1800\n2;\"GK\"\"12\";一开双;700\n";
        byte[] gbk = text.getBytes(Charset.forName("GBK"));
        Sheet sheet = SpreadsheetGridReader.read(gbk, DocumentKind.CSV).sheets().getFirst();
        assertThat(sheet.text(0, 1)).isEqualTo("型号");
        assertThat(sheet.text(1, 2)).isEqualTo("两开多功能\n三极插座");
        assertThat(sheet.row(1).cell(3).number()).isEqualByComparingTo("1800");
        assertThat(sheet.text(2, 1)).isEqualTo("GK\"12");
    }

    @Test
    void csvUtf8WithBomAndCommas() {
        byte[] bom = {(byte) 0xEF, (byte) 0xBB, (byte) 0xBF};
        byte[] body = "Part No,Description,Qty\nKCL-01,curtain switch 窗帘开关,\"5,000\"\n".getBytes(StandardCharsets.UTF_8);
        byte[] bytes = new byte[bom.length + body.length];
        System.arraycopy(bom, 0, bytes, 0, bom.length);
        System.arraycopy(body, 0, bytes, bom.length, body.length);
        Sheet sheet = SpreadsheetGridReader.read(bytes, DocumentKind.CSV).sheets().getFirst();
        assertThat(sheet.text(0, 0)).isEqualTo("Part No");
        assertThat(sheet.text(1, 1)).isEqualTo("curtain switch 窗帘开关");
        assertThat(sheet.text(1, 2)).isEqualTo("5,000");
    }

    @Test
    void csvNumericLookingCodesKeepLeadingZeros() {
        byte[] bytes = "Part No,Qty,Price\n00123,0500,1.50\n".getBytes(StandardCharsets.UTF_8);
        Sheet sheet = SpreadsheetGridReader.read(bytes, DocumentKind.CSV).sheets().getFirst();
        assertThat(sheet.text(1, 0)).isEqualTo("00123");
        assertThat(sheet.row(1).cell(0).kind()).isEqualTo(DocumentGrid.CellKind.NUMBER);
        assertThat(sheet.row(1).cell(0).number()).isEqualByComparingTo("123");
        assertThat(sheet.text(1, 1)).isEqualTo("0500");
        assertThat(sheet.row(1).cell(1).number()).isEqualByComparingTo("500");
        assertThat(sheet.row(1).cell(2).number()).isEqualByComparingTo("1.5");
    }

    @Test
    void columnLetterHelpers() {
        assertThat(DocumentGrid.columnLetter(0)).isEqualTo("A");
        assertThat(DocumentGrid.columnLetter(25)).isEqualTo("Z");
        assertThat(DocumentGrid.columnLetter(26)).isEqualTo("AA");
        assertThat(DocumentGrid.columnIndex("IU")).isEqualTo(254);
        assertThat(DocumentGrid.columnIndex("1A")).isEqualTo(-1);
        assertThat(SpreadsheetGridReader.parseRange("Q8:S8")).isEqualTo(new DocumentGrid.MergedRange(7, 7, 16, 18));
    }
}
