package com.uten.imp.common.export;

import org.junit.jupiter.api.Test;
import org.xml.sax.Attributes;
import org.xml.sax.helpers.DefaultHandler;

import javax.xml.parsers.SAXParserFactory;
import java.io.ByteArrayInputStream;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CancellationException;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.stream.IntStream;
import java.util.zip.ZipInputStream;

import static org.assertj.core.api.Assertions.*;

class XlsxCompleteSourceTest {
    private static final List<ExportColumn> COLUMNS = List.of(new ExportColumn("code", "货品编码", ExportColumn.TEXT));

    @Test void directDownloadStreamsAll1201RowsAndRetainsNoSourceRows() throws Exception {
        var calls = new AtomicInteger();
        var result = new XlsxExportService().buildSource(() -> emit(1201, calls), null, null);
        assertThat(calls).hasValue(13);
        assertThat(result.payload().rows()).isEmpty();
        assertThat(result.payload().total()).isEqualTo(1201);
        assertWorkbook(result.bytes(), 1201, 1, "货品-1200");
        assertThat(ExportPageSink.current()).isNull();
    }

    @Test void allRowsContinueInANewSheetAtTheActualExcelFormatBoundary() throws Exception {
        int total = 1_048_600;
        var result = new XlsxExportService().buildSource(() -> emit(total, new AtomicInteger()), null, null);
        assertWorkbook(result.bytes(), total, 2, "货品-1048599");
    }

    @Test void anInterruptedReadNeverPublishesAnEarlierCompleteBatch() {
        assertThatThrownBy(() -> new XlsxExportService().buildSource(() -> {
            ExportPageSink.current().accept(new ExportPayload(COLUMNS,
                    IntStream.range(0, 500).mapToObj(i -> Map.<String, Object>of("code", "货品-" + i)).toList(), 500));
            throw new CancellationException();
        }, null, null)).isInstanceOf(CancellationException.class);
        assertThat(ExportPageSink.current()).isNull();
    }

    @Test void sourceCountMismatchRefusesTheWholeFile() {
        assertThatThrownBy(() -> new XlsxExportService().buildSource(() -> {
            ExportPageSink.current().accept(new ExportPayload(COLUMNS, List.of(Map.of("code", "first")), 1));
            return new ExportPayload(COLUMNS, List.of(), 1201);
        }, null, null)).isInstanceOf(IllegalStateException.class).hasMessageContaining("incomplete");
        assertThat(ExportPageSink.current()).isNull();
    }

    private static ExportPayload emit(int total, AtomicInteger calls) {
        for (int start = 0; start < total; start += 100) {
            var rows = IntStream.range(start, Math.min(total, start + 100))
                    .mapToObj(i -> Map.<String, Object>of("code", "货品-" + i)).toList();
            ExportPageSink.current().accept(new ExportPayload(COLUMNS, rows, start + rows.size()));
            calls.incrementAndGet();
        }
        return new ExportPayload(COLUMNS, List.of(), total);
    }

    private static void assertWorkbook(byte[] bytes, int expectedRows, int expectedSheets, String lastValue) throws Exception {
        var rows = new AtomicInteger();
        var sheets = new AtomicInteger();
        var lastSeen = new java.util.concurrent.atomic.AtomicBoolean();
        var factory = SAXParserFactory.newInstance();
        factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
        var artifact=java.nio.file.Files.createTempFile("complete-export-", ".xlsx");
        java.nio.file.Files.write(artifact, bytes);
        try (var zip = new java.util.zip.ZipFile(artifact.toFile())) {
            var entries=zip.entries();
            while(entries.hasMoreElements()) {
                var entry=entries.nextElement();
                if (!entry.getName().matches("xl/worksheets/sheet\\d+\\.xml")) continue;
                sheets.incrementAndGet();
                var handler = new DefaultHandler() {
                    StringBuilder text;
                    @Override public void startElement(String uri, String local, String name, Attributes attributes) {
                        if (name.equals("row")) rows.incrementAndGet();
                        if (name.equals("t")) text = new StringBuilder();
                    }
                    @Override public void characters(char[] ch, int start, int length) {
                        if (text != null) text.append(ch, start, length);
                    }
                    @Override public void endElement(String uri, String local, String name) {
                        if (name.equals("t")) {
                            if (lastValue.contentEquals(text)) {
                                lastSeen.set(true);
                            }
                            text = null;
                        }
                    }
                };
                try(var input=zip.getInputStream(entry)) { factory.newSAXParser().parse(input, handler); }
            }
        }
        finally { java.nio.file.Files.deleteIfExists(artifact); }
        assertThat(sheets).hasValue(expectedSheets);
        assertThat(rows.get() - sheets.get()).isEqualTo(expectedRows);
        assertThat(lastSeen).isTrue();
    }
}
