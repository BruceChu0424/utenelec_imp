package com.uten.imp.common.export;

import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.apache.poi.poifs.filesystem.POIFSFileSystem;
import org.apache.poi.poifs.crypt.Decryptor;
import org.apache.poi.poifs.crypt.EncryptionInfo;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import java.io.*;
import java.math.BigDecimal;
import java.nio.file.*;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;

class StreamingWorkbookTest {
    @TempDir Path directory;
    private static List<ExportColumn> columns() {
        return List.of(new ExportColumn("qty","数量",ExportColumn.QTY),new ExportColumn("note","原文",ExportColumn.TEXT));
    }
    @Test void pagesAndOptionalDiskEncryptionRetainExactNumbersAndFormulaLiteralText() throws Exception {
        Path plain=directory.resolve("plain.xlsx");Path encrypted=directory.resolve("protected.xlsx");
        var service=new XlsxExportService();
        try(var stream=service.openStream(null,null,directory);var output=Files.newOutputStream(plain)) {
            stream.accept(new ExportPayload(columns(),List.of(Map.of("qty",new BigDecimal("1234567890123456.01"),"note","=HYPERLINK(\"a\")")),1));
            stream.accept(new ExportPayload(columns(),List.of(Map.of("qty",new BigDecimal("0.0001234567"),"note","第二页原文")),2));
            assertEquals(2,stream.rowCount());stream.finish(output);
        }
        try(var files=Files.list(directory)) { assertTrue(files.noneMatch(p -> p.getFileName().toString().startsWith("report-sheet-"))); }
        new WorkbookDownloadService().protect(plain,encrypted,"test-only");
        try(var fs=new POIFSFileSystem(encrypted.toFile(),true)) {
            var decryptor=Decryptor.getInstance(new EncryptionInfo(fs));assertTrue(decryptor.verifyPassword("test-only"));
            try(var input=decryptor.getDataStream(fs);var book=new XSSFWorkbook(input)) {
                var sheet=book.getSheetAt(0);assertEquals(2,sheet.getLastRowNum());
                assertEquals("1234567890123456.01",sheet.getRow(1).getCell(0).getStringCellValue());
                assertEquals("=HYPERLINK(\"a\")",sheet.getRow(1).getCell(1).getStringCellValue());
                assertEquals(org.apache.poi.ss.usermodel.CellType.STRING,sheet.getRow(1).getCell(1).getCellType());
                assertEquals("第二页原文",sheet.getRow(2).getCell(1).getStringCellValue());
            }
        }
    }
    @Test void emptyResultProducesHeadersAndColumnChangesFailBeforePublication() throws Exception {
        try(var writer=new XlsxExportService().openStream(null,null)) {
            writer.accept(new ExportPayload(columns(),List.of(),0));
            assertThrows(IllegalStateException.class,() -> writer.accept(new ExportPayload(List.of(),List.of(),0)));
            var output=new ByteArrayOutputStream();writer.finish(output);
            try(var book=new XSSFWorkbook(new ByteArrayInputStream(output.toByteArray()))) {
                assertEquals("数量",book.getSheetAt(0).getRow(0).getCell(0).getStringCellValue());
            }
        }
    }
}
