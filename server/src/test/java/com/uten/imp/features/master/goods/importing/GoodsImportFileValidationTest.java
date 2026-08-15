package com.uten.imp.features.master.goods.importing;

import com.uten.imp.common.web.ApiException;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Locks the user-facing validation contract for malformed import workbooks. */
class GoodsImportFileValidationTest {

    private final GoodsImportService service = new GoodsImportService(
            null, null, null, null, null, null, null, null, null, null);

    @Test
    void detect_rejectsEmptyFileWithRecoveryMessage() {
        ApiException error = assertThrows(ApiException.class, () -> service.detect(new byte[0]));

        assertTrue(error.getMessage().contains("文件为空"));
    }

    @Test
    void detect_rejectsLegacyOrEncryptedOleContainer() {
        byte[] oleHeader = new byte[]{
                (byte) 0xD0, (byte) 0xCF, 0x11, (byte) 0xE0,
                (byte) 0xA1, (byte) 0xB1, 0x1A, (byte) 0xE1
        };

        ApiException error = assertThrows(ApiException.class, () -> service.detect(oleHeader));

        assertTrue(error.getMessage().contains("未加密的 .xlsx"));
    }

    @Test
    void detect_convertsCorruptZipParserFailureToValidationError() {
        byte[] corruptZip = new byte[]{0x50, 0x4B, 0x03, 0x04, 0x00, 0x00};

        ApiException error = assertThrows(ApiException.class, () -> service.detect(corruptZip));

        assertTrue(error.getMessage().contains("无法"));
        assertTrue(error.getMessage().contains("未加密的 .xlsx"));
    }

    @Test
    void detect_rejectsWorkbookWithoutSheets() throws Exception {
        byte[] workbookBytes;
        try (XSSFWorkbook workbook = new XSSFWorkbook();
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            workbook.write(output);
            workbookBytes = output.toByteArray();
        }

        ApiException error = assertThrows(ApiException.class, () -> service.detect(workbookBytes));

        assertTrue(error.getMessage().contains("不包含工作表"));
    }

    @Test
    void archiveGuard_acceptsAPlainBoundedWorkbook() throws Exception {
        byte[] workbookBytes;
        try (XSSFWorkbook workbook = new XSSFWorkbook();
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            var sheet = workbook.createSheet("商品");
            var header = sheet.createRow(0);
            header.createCell(0).setCellValue("编号");
            header.createCell(1).setCellValue("名称");
            header.createCell(2).setCellValue("类别");
            GoodsImportWorkbookSecurity.inspectWorkbook(workbook);
            workbook.write(output);
            workbookBytes = output.toByteArray();
        }

        assertDoesNotThrow(() -> GoodsImportWorkbookSecurity.inspectArchive(workbookBytes));
    }

    @Test
    void archiveGuard_rejectsHighlyCompressedExpandedContent() throws Exception {
        byte[] archive = zipWithEntries(
                new Entry("[Content_Types].xml", new byte[]{1}),
                new Entry("_rels/.rels", new byte[]{1}),
                new Entry("xl/workbook.xml", new byte[]{1}),
                new Entry("xl/_rels/workbook.xml.rels", new byte[]{1}),
                new Entry("xl/worksheets/sheet1.xml", new byte[1024 * 1024]));

        ApiException error = assertThrows(
                ApiException.class,
                () -> GoodsImportWorkbookSecurity.inspectArchive(archive));

        assertTrue(error.getMessage().contains("压缩比例异常"));
    }

    @Test
    void archiveGuard_rejectsExternalLinksAndEmbeddedActiveContent() throws Exception {
        byte[] archive = zipWithEntries(
                new Entry("[Content_Types].xml", new byte[]{1}),
                new Entry("_rels/.rels", new byte[]{1}),
                new Entry("xl/workbook.xml", new byte[]{1}),
                new Entry("xl/_rels/workbook.xml.rels", new byte[]{1}),
                new Entry("xl/externalLinks/externalLink1.xml", new byte[]{1}));

        ApiException error = assertThrows(
                ApiException.class,
                () -> GoodsImportWorkbookSecurity.inspectArchive(archive));

        assertTrue(error.getMessage().contains("外部链接"));
    }

    @Test
    void workbookGuard_rejectsFormulaCellsBeforeBusinessParsing() throws Exception {
        try (XSSFWorkbook workbook = new XSSFWorkbook()) {
            var sheet = workbook.createSheet("商品");
            sheet.createRow(0).createCell(0).setCellFormula("1+1");

            ApiException error = assertThrows(
                    ApiException.class,
                    () -> GoodsImportWorkbookSecurity.inspectWorkbook(workbook));

            assertTrue(error.getMessage().contains("不执行公式"));
        }
    }

    private static byte[] zipWithEntries(Entry... entries) throws Exception {
        try (ByteArrayOutputStream output = new ByteArrayOutputStream();
             ZipOutputStream zip = new ZipOutputStream(output)) {
            for (Entry entry : entries) {
                zip.putNextEntry(new ZipEntry(entry.name()));
                try (ByteArrayInputStream input = new ByteArrayInputStream(entry.content())) {
                    input.transferTo(zip);
                }
                zip.closeEntry();
            }
            zip.finish();
            return output.toByteArray();
        }
    }

    private record Entry(String name, byte[] content) {
    }
}
