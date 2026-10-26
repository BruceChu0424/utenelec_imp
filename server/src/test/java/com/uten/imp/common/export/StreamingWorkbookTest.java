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

    @Test void concurrentExportsKeepPrivateSheetFilesAndRawRowsInTheirOwnDirectories() throws Exception {
        Path first=Files.createDirectory(directory.resolve("first"));
        Path second=Files.createDirectory(directory.resolve("second"));
        var service=new XlsxExportService();
        var together=new java.util.concurrent.CyclicBarrier(2);
        try(var workers=java.util.concurrent.Executors.newFixedThreadPool(2)) {
            var one=workers.submit(()->writeConcurrentExport(service,first,"first",together));
            var two=workers.submit(()->writeConcurrentExport(service,second,"second",together));
            for(var result:List.of(one,two)) {
                byte[] bytes=result.get(30,java.util.concurrent.TimeUnit.SECONDS);
                try(var book=new XSSFWorkbook(new ByteArrayInputStream(bytes))) {
                    var sheet=book.getSheetAt(0);assertEquals(501,sheet.getLastRowNum());
                    String marker=sheet.getRow(1).getCell(1).getStringCellValue();
                    assertTrue(Set.of("first","second").contains(marker));
                    assertEquals(marker,sheet.getRow(501).getCell(1).getStringCellValue());
                }
            }
        }
        for(Path export:List.of(first,second))try(var files=Files.list(export)){assertEquals(0,files.count());}
    }

    private static byte[] writeConcurrentExport(XlsxExportService service,Path export,String marker,
            java.util.concurrent.CyclicBarrier together)throws Exception {
        try(var stream=service.openStream(null,null,export);var out=new ByteArrayOutputStream()) {
            var rows=java.util.stream.IntStream.range(0,501).mapToObj(index->Map.<String,Object>of("qty",index,"note",marker)).toList();
            stream.accept(new ExportPayload(columns(),rows,501));
            together.await(10,java.util.concurrent.TimeUnit.SECONDS);
            try(var files=Files.list(export)){assertTrue(files.anyMatch(path->path.getFileName().toString().startsWith("report-sheet-")));}
            stream.finish(out);return out.toByteArray();
        }
    }

    @Test void aFailedPrivateSheetCreationRestoresAnExistingPoiThreadStrategy() throws Exception {
        Path outer=Files.createDirectory(directory.resolve("outer"));
        Path blocked=directory.resolve("not-a-directory");Files.writeString(blocked,"fixture");
        var previous=new org.apache.poi.util.DefaultTempFileCreationStrategy(outer.toFile());
        org.apache.poi.util.TempFile.withStrategy(previous,()->{
            assertThrows(RuntimeException.class,()->{
                try(var writer=new XlsxExportService().openStream(null,null,blocked)) {
                    writer.accept(new ExportPayload(columns(),List.of(),0));
                }
            });
            try {
                File probe=org.apache.poi.util.TempFile.createTempFile("restored-",".tmp");
                assertTrue(probe.toPath().startsWith(outer));Files.delete(probe.toPath());
            } catch(IOException failure) { throw new java.io.UncheckedIOException(failure); }
            return null;
        });
    }
}
