package com.uten.imp.common.export;

import org.apache.poi.ss.usermodel.CellType;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.*;
import java.math.BigDecimal;
import java.nio.file.*;
import java.util.*;
import java.util.stream.IntStream;

import static org.junit.jupiter.api.Assertions.*;

class StreamingDocumentWriterTest {
    @TempDir Path directory;
    private static List<ExportColumn> columns(){return List.of(
            new ExportColumn("name","产品名称",ExportColumn.TEXT),
            new ExportColumn("qty","原始数量",ExportColumn.QTY,null,"箱",null));}
    private static DocumentPageSink.Header header(long expected){return new DocumentPageSink.Header("物料反查与追溯",
            List.of("操作员：服务器解析姓名(E001)","历史证据不跨来源相加"),List.of(
            new DocumentPageSink.Section("main","组件使用产品",columns(),true,false),
            new DocumentPageSink.Section("current","当前组装依据",columns(),false,true),
            new DocumentPageSink.Section("execution","新生产需求依据",columns(),false,true),
            new DocumentPageSink.Section("legacy","旧生产快照依据",columns(),false,true),
            new DocumentPageSink.Section("subcontract","委外需求与历史依据",columns(),false,true)),expected);}
    private static List<Map<String,Object>> rows(int start,int end){return IntStream.range(start,end)
            .mapToObj(index->Map.<String,Object>of("name",index==0?"=HYPERLINK(\"https://example.invalid\")":"产品-"+index,
                    "qty",new BigDecimal("0.123456789012345678901234567890"))).toList();}

    @Test void interleavedSectionsRetainDeclaredOrderExactCellsAndPrimaryProgress()throws Exception {
        Path file=directory.resolve("multi.xlsx");var service=new XlsxExportService();
        try(var writer=service.openDocumentStream(directory);var output=Files.newOutputStream(file)) {
            writer.begin(header(201));writer.accept(new DocumentPageSink.Page("main",rows(0,200)));
            writer.accept(new DocumentPageSink.Page("legacy",rows(8,11)));
            writer.accept(new DocumentPageSink.Page("main",rows(200,201)));
            writer.accept(new DocumentPageSink.Page("current",rows(20,22)));
            assertEquals(201,writer.primaryRowCount());assertEquals(206,writer.rowCount());writer.finish(output);
        }
        try(var input=Files.newInputStream(file);var workbook=new XSSFWorkbook(input)) {
            assertEquals(List.of("说明","组件使用产品","当前组装依据","旧生产快照依据"),
                    IntStream.range(0,workbook.getNumberOfSheets()).mapToObj(workbook::getSheetName).toList());
            var main=workbook.getSheetAt(1);assertEquals(201,main.getLastRowNum());
            var formula=main.getRow(1).getCell(0);assertEquals(CellType.STRING,formula.getCellType());
            assertEquals("=HYPERLINK(\"https://example.invalid\")",formula.getStringCellValue());
            var exact=main.getRow(201).getCell(1);assertEquals(CellType.STRING,exact.getCellType());
            assertEquals("0.123456789012345678901234567890",exact.getStringCellValue());
            assertTrue(exact.getCellStyle().getDataFormatString().contains("箱"));
            assertNotNull(main.getPaneInformation());
        }
        assertNoSheetTemps();
    }

    @Test void primaryCountMismatchUnknownSectionAndInterruptedWriteCannotPublish()throws Exception {
        try(var writer=new XlsxExportService().openDocumentStream(directory)) {
            writer.begin(header(1));
            assertThrows(IllegalStateException.class,()->writer.finish(new ByteArrayOutputStream()));
            assertThrows(IllegalStateException.class,()->writer.accept(new DocumentPageSink.Page("main",rows(0,1))));
        }
        try(var writer=new XlsxExportService().openDocumentStream(directory)) {
            writer.begin(header(1));
            assertThrows(IllegalArgumentException.class,()->writer.accept(new DocumentPageSink.Page("unknown",rows(0,1))));
            assertThrows(IllegalStateException.class,()->writer.finish(new ByteArrayOutputStream()));
        }
        try(var writer=new XlsxExportService().openDocumentStream(directory)) {
            writer.begin(header(1));
            Thread.currentThread().interrupt();
            try{assertThrows(java.util.concurrent.CancellationException.class,()->writer.accept(new DocumentPageSink.Page("main",rows(0,1))));}
            finally{Thread.interrupted();}
            assertThrows(IllegalStateException.class,()->writer.finish(new ByteArrayOutputStream()));
        }
        assertNoSheetTemps();
    }

    @Test void outputFailureCleansEveryPrivateSheetAndCannotRetry()throws Exception {
        try(var writer=new XlsxExportService().openDocumentStream(directory)) {
            writer.begin(header(1));writer.accept(new DocumentPageSink.Page("main",rows(0,1)));
            assertThrows(IOException.class,()->writer.finish(new OutputStream(){public void write(int value)throws IOException{throw new IOException("injected destination failure");}}));
            assertThrows(IllegalStateException.class,()->writer.finish(new ByteArrayOutputStream()));
        }
        assertNoSheetTemps();
    }

    @Test void emptyMandatorySheetAndDuplicateSafeNamesPreserveAllSections()throws Exception {
        var header=new DocumentPageSink.Header("来源",List.of(),List.of(
                new DocumentPageSink.Section("first","A/B",columns(),true,false),
                new DocumentPageSink.Section("second","A?B",columns(),false,false),
                new DocumentPageSink.Section("info","说明",columns(),false,false)),0);
        var bytes=new ByteArrayOutputStream();
        try(var writer=new XlsxExportService().openDocumentStream(directory)){writer.begin(header);writer.finish(bytes);}
        try(var workbook=new XSSFWorkbook(new ByteArrayInputStream(bytes.toByteArray()))) {
            assertEquals(4,workbook.getNumberOfSheets());
            assertEquals(4,IntStream.range(0,4).mapToObj(workbook::getSheetName).distinct().count());
            assertEquals("产品名称",workbook.getSheetAt(1).getRow(0).getCell(0).getStringCellValue());
        }
    }

    @Test void doubleRangeBoundariesRemainExactTextWithoutAllocatingUnboundedPlainStrings()throws Exception {
        var values=List.of(new BigDecimal("1E400"),new BigDecimal("1E-400"),new BigDecimal("0.0100"));
        byte[] bytes=new XlsxExportService().build(List.of(new ExportColumn("n","数值",ExportColumn.QTY)),
                values.stream().map(value->Map.<String,Object>of("n",value)).toList());
        try(var book=new XSSFWorkbook(new ByteArrayInputStream(bytes))) {
            var sheet=book.getSheetAt(0);
            for(int index=0;index<2;index++) {
                var cell=sheet.getRow(index+1).getCell(0);assertEquals(CellType.STRING,cell.getCellType());
                assertEquals(0,new BigDecimal(cell.getStringCellValue()).compareTo(values.get(index)));
            }
            assertEquals(CellType.NUMERIC,sheet.getRow(3).getCell(0).getCellType());
            assertEquals(.01,sheet.getRow(3).getCell(0).getNumericCellValue());
        }
        assertThrows(com.uten.imp.common.web.ApiException.class,()->ExportCellValues.exactText(new BigDecimal("1E-10000000")));
    }

    @Test void temporaryQuotaAndCleanupAttemptEveryOwnedFileAfterAnEarlierFailure()throws Exception {
        var budget=new ExportTemporaryBudget(directory);
        assertThrows(IOException.class,()->budget.before(Math.toIntExact(ExportResourceLimits.SHEET_TEMP_BYTES+1)));
        Path bad=Files.createDirectory(directory.resolve("cannot-delete-as-file"));Files.writeString(bad.resolve("child"),"owned fixture");
        Path good=Files.writeString(directory.resolve("must-still-delete"),"owned fixture");
        budget.files.add(bad);budget.files.add(good);
        assertThrows(IOException.class,budget::cleanupFiles);assertFalse(Files.exists(good));assertTrue(Files.exists(bad.resolve("child")));
    }
    @Test void normalAndAbandonedWindowsDoNotLogClosedSheetFailuresAndClosedWritersStayClosed()throws Exception {
        var logger=(ch.qos.logback.classic.Logger)org.slf4j.LoggerFactory.getLogger(org.apache.poi.xssf.streaming.SXSSFWorkbook.class);
        var captured=new ch.qos.logback.core.read.ListAppender<ch.qos.logback.classic.spi.ILoggingEvent>();captured.start();logger.addAppender(captured);
        try {
            try(var writer=new XlsxExportService().openDocumentStream(directory)){writer.begin(header(0));writer.finish(new ByteArrayOutputStream());}
            var abandoned=new XlsxExportService().openDocumentStream(directory);abandoned.begin(header(1));
            abandoned.accept(new DocumentPageSink.Page("main",rows(0,1)));abandoned.close();abandoned.close();
            assertThrows(IllegalStateException.class,()->abandoned.accept(new DocumentPageSink.Page("main",rows(0,1))));
            assertThrows(IllegalStateException.class,()->abandoned.finish(new ByteArrayOutputStream()));
            assertTrue(captured.list.stream().noneMatch(event->event.getLevel().isGreaterOrEqual(ch.qos.logback.classic.Level.WARN)),
                    captured.list.stream().map(ch.qos.logback.classic.spi.ILoggingEvent::getFormattedMessage).toList().toString());
        }finally{logger.detachAppender(captured);captured.stop();}
        assertNoSheetTemps();
    }
    @Test void unknownCountDocumentsStopAtTheOriginalSectionBoundaryInBothWriters()throws Exception {
        var column=List.of(new ExportColumn("q","数量",ExportColumn.QTY));
        var header=new DocumentPageSink.Header("未知总数",List.of(),List.of(new DocumentPageSink.Section("main","数据",column,true,false)));
        var page=new DocumentPageSink.Page("main",Collections.nCopies(200,Map.<String,Object>of("q",1)));
        for(boolean pdf:List.of(false,true)) {
            try(var writer=pdf?new TabularPdfExportService().openDocumentStream(directory):new XlsxExportService().openDocumentStream(directory)) {
                writer.begin(header);
                for(int index=0;index<ExportDocument.MAX_SECTION_ROWS/200;index++)writer.accept(page);
                assertEquals(ExportDocument.MAX_SECTION_ROWS,writer.primaryRowCount());
                assertThrows(com.uten.imp.common.web.ApiException.class,()->writer.accept(new DocumentPageSink.Page("main",List.of(Map.of("q",1)))));
                assertThrows(IllegalStateException.class,()->writer.finish(new ByteArrayOutputStream()));
            }
            try(var files=Files.list(directory)){assertTrue(files.findAny().isEmpty());}
        }
    }
    private void assertNoSheetTemps()throws IOException {
        try(var files=Files.list(directory)){assertTrue(files.noneMatch(path->path.getFileName().toString().startsWith("report-sheet-")));}
    }
}
