package com.uten.imp.common.export;

import com.uten.imp.common.web.ApiException;
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.text.PDFTextStripper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.*;
import java.math.BigDecimal;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.CancellationException;
import java.util.stream.IntStream;

import static org.junit.jupiter.api.Assertions.*;

class StreamingPdfDocumentTest {
    @TempDir Path directory;
    private static final BigDecimal EXACT=new BigDecimal("0.123456789012345678901234567890");
    private static List<ExportColumn> columns(){return List.of(
            new ExportColumn("name","产品名称",ExportColumn.TEXT),
            new ExportColumn("qty","原始数量",ExportColumn.QTY,null,"箱",null),
            new ExportColumn("literal","历史原文",ExportColumn.TEXT));}
    private static DocumentPageSink.Header header(long count){return new DocumentPageSink.Header("物料反查与追溯 · 来源证据",
            List.of("操作员：服务器姓名(E001)","不同来源数量不相加；历史单位不推定"),List.of(
            new DocumentPageSink.Section("main","组件使用产品",columns(),true,false),
            new DocumentPageSink.Section("history","旧生产快照依据",List.of(new ExportColumn("name","产品名称",ExportColumn.TEXT),
                    new ExportColumn("qty","历史证据数量",ExportColumn.QTY)),false,true)),count);}
    private static List<Map<String,Object>> rows(int start,int end){return IntStream.range(start,end).mapToObj(index->Map.<String,Object>of(
            "name",String.format("产品-%04d",index),"qty",index==200?EXACT:BigDecimal.ONE,
            "literal",index==0?"=SUM(1,2)":"原文完整来源")).toList();}

    @Test void diskSpoolUsesAllPagesForWidthExactQuantitiesAndSectionIdentityThenProtectsCopy()throws Exception {
        Path plain=directory.resolve("plain.pdf"),encrypted=directory.resolve("protected.pdf");
        var service=new TabularPdfExportService();
        try(var writer=service.openDocumentStream(directory);var output=Files.newOutputStream(plain)) {
            writer.begin(header(201));writer.accept(new DocumentPageSink.Page("main",rows(0,200)));
            writer.accept(new DocumentPageSink.Page("history",rows(8,9)));
            writer.accept(new DocumentPageSink.Page("main",rows(200,201)));
            assertEquals(201,writer.primaryRowCount());assertEquals(202,writer.rowCount());writer.finish(output);
        }
        try(var pdf=Loader.loadPDF(plain.toFile())) {
            assertFalse(pdf.isEncrypted());String text=new PDFTextStripper().getText(pdf);
            assertTrue(text.contains("服务器姓名(E001)"));assertTrue(text.contains("旧生产快照依据"));
            assertTrue(text.contains(EXACT.toPlainString()));assertTrue(text.contains("箱"));assertTrue(text.contains("=SUM(1,2)"));
            for(int index=0;index<201;index++)assertTrue(text.contains(String.format("产品-%04d",index)),"Missing original identity "+index);
            assertTrue(pdf.getNumberOfPages()>2);assertTrue(pdf.getNumberOfPages()<=250);
        }
        byte[] original=Files.readAllBytes(plain);
        service.protect(plain,encrypted,"1"); // Existing password contract permits short passwords.
        assertArrayEquals(original,Files.readAllBytes(plain),"Download protection must never rewrite the captured source");
        try(var pdf=Loader.loadPDF(encrypted.toFile(),"1")){assertTrue(pdf.isEncrypted());assertTrue(new PDFTextStripper().getText(pdf).contains(EXACT.toPlainString()));}
        assertThrows(org.apache.pdfbox.pdmodel.encryption.InvalidPasswordException.class,()->Loader.loadPDF(encrypted.toFile(),"wrong"));
        Path visual=Path.of("target-b1-document-validation","where-used-document.pdf");Files.createDirectories(visual.getParent());
        Files.copy(plain,visual,StandardCopyOption.REPLACE_EXISTING);
        assertNoPrivateDirectories();
    }

    @Test void readBudgetAndActualCellBudgetFailClosedBeforeFurtherRows()throws Exception {
        try(var writer=new TabularPdfExportService().openDocumentStream(directory)) {
            assertThrows(ApiException.class,()->writer.begin(header(60_001)));
            assertThrows(IllegalStateException.class,()->writer.finish(new ByteArrayOutputStream()));
        }
        var wide=IntStream.range(0,160).mapToObj(index->new ExportColumn("c"+index,"列"+index,ExportColumn.TEXT)).toList();
        var unknown=new DocumentPageSink.Header("预算",List.of(),List.of(new DocumentPageSink.Section("main","数据",wide,true,false)));
        try(var writer=new TabularPdfExportService().openDocumentStream(directory)) {
            writer.begin(unknown);writer.accept(new DocumentPageSink.Page("main",Collections.nCopies(200,Map.of())));
            assertThrows(ApiException.class,()->writer.accept(new DocumentPageSink.Page("main",Collections.nCopies(200,Map.of()))));
            assertEquals(200,writer.primaryRowCount());assertThrows(IllegalStateException.class,()->writer.finish(new ByteArrayOutputStream()));
        }
        assertNoPrivateDirectories();
    }

    @Test void taskCheckpointCancellationAndOutputFailurePoisonWriterAndCleanSpools()throws Exception {
        try(var writer=new TabularPdfExportService().openDocumentStream(directory)) {
            writer.onCheckpoint(()->{throw new CancellationException("task cancelled");});
            assertThrows(CancellationException.class,()->writer.begin(header(1)));
            assertThrows(IllegalStateException.class,()->writer.finish(new ByteArrayOutputStream()));
        }
        try(var writer=new TabularPdfExportService().openDocumentStream(directory)) {
            writer.begin(header(1));writer.accept(new DocumentPageSink.Page("main",rows(0,1)));
            assertThrows(IOException.class,()->writer.finish(new OutputStream(){public void write(int value)throws IOException{throw new IOException("injected output failure");}}));
            assertThrows(IllegalStateException.class,()->writer.accept(new DocumentPageSink.Page("main",rows(0,1))));
        }
        assertNoPrivateDirectories();
    }

    @Test void preciseUnrenderableQuantityAndPageLimitRefuseMisleadingOrPartialPdf()throws Exception {
        try(var writer=new TabularPdfExportService().openDocumentStream(directory)) {
            writer.begin(header(1));writer.accept(new DocumentPageSink.Page("main",List.of(Map.of("name","产品","qty",new BigDecimal("1E400"),"literal","原文"))));
            assertThrows(ApiException.class,()->writer.finish(new ByteArrayOutputStream()));
        }
        var one=List.of(new ExportColumn("name","产品名称",ExportColumn.TEXT));
        try(var writer=new TabularPdfExportService().openDocumentStream(directory)) {
            writer.begin(new DocumentPageSink.Header("页数预算",List.of(),List.of(new DocumentPageSink.Section("main","原始数据",one,true,false)),8000));
            for(int start=0;start<8000;start+=200)writer.accept(new DocumentPageSink.Page("main",rows(start,start+200)));
            var failure=assertThrows(ApiException.class,()->writer.finish(new ByteArrayOutputStream()));assertTrue(failure.getMessage().contains("250"));
        }
        assertNoPrivateDirectories();
    }

    @Test void corruptProtectionAndInvalidPasswordLeaveNoPartialCopyOrScratch()throws Exception {
        Path source=Files.writeString(directory.resolve("bad.pdf"),"not a PDF");Path target=directory.resolve("target.pdf");
        var service=new TabularPdfExportService();
        assertThrows(IOException.class,()->service.protect(source,target,"password"));assertFalse(Files.exists(target));
        assertEquals("not a PDF",Files.readString(source));assertNoPrivateDirectories();
        assertThrows(IllegalArgumentException.class,()->service.protect(source,target,"x".repeat(129)));
        assertFalse(Files.exists(target));
    }
    private void assertNoPrivateDirectories()throws IOException {
        try(var files=Files.list(directory)){assertTrue(files.noneMatch(path->Files.isDirectory(path)&&path.getFileName().toString().startsWith("report-")));}
    }
}
