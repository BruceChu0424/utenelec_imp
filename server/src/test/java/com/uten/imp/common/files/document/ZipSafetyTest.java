package com.uten.imp.common.files.document;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ZipSafetyTest {

    private static Map<String, byte[]> minimal() {
        Map<String, byte[]> entries = new LinkedHashMap<>();
        entries.put("[Content_Types].xml", "<Types/>".getBytes(StandardCharsets.UTF_8));
        entries.put("xl/workbook.xml", "<workbook/>".getBytes(StandardCharsets.UTF_8));
        return entries;
    }

    @Test
    void acceptsMinimalWorkbookAndMedia() {
        Map<String, byte[]> entries = minimal();
        entries.put("xl/media/image1.png", new byte[4096]);
        entries.put("xl/printerSettings/printerSettings1.bin", new byte[128]);
        assertThat(ZipSafety.inspectSpreadsheet(DocumentReaderTestSupport.zip(entries))).contains("xl/media/image1.png");
    }

    @Test
    void rejectsZipBombSheet() {
        Map<String, byte[]> entries = minimal();
        entries.put("xl/worksheets/sheet1.xml", new byte[(int) ZipSafety.MAX_SHEET_XML_BYTES + 1024]);
        assertThatThrownBy(() -> ZipSafety.inspectSpreadsheet(DocumentReaderTestSupport.zip(entries)))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void rejectsHugeExpansionOfNonMediaParts() {
        Map<String, byte[]> entries = minimal();
        for (int i = 0; i < 5; i++) {
            entries.put("xl/worksheets/sheet" + i + ".xml", new byte[7 * 1024 * 1024]);
        }
        assertThatThrownBy(() -> ZipSafety.inspectSpreadsheet(DocumentReaderTestSupport.zip(entries)))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void rejectsActiveContentAndBadPaths() {
        for (String bad : new String[]{"xl/vbaProject.bin", "xl/externalLinks/externalLink1.xml", "xl/activeX/activeX1.xml",
                "xl/embeddings/oleObject1.bin", "customXml/item1.xml", "xl/connections.xml"}) {
            Map<String, byte[]> entries = minimal();
            entries.put(bad, new byte[8]);
            assertThatThrownBy(() -> ZipSafety.inspectSpreadsheet(DocumentReaderTestSupport.zip(entries)))
                    .as(bad).isInstanceOf(ApiException.class);
        }
        Map<String, byte[]> traversal = minimal();
        traversal.put("../evil.xml", new byte[8]);
        assertThatThrownBy(() -> ZipSafety.inspectSpreadsheet(DocumentReaderTestSupport.zip(traversal)))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void rejectsArchivesThatAreNotWorkbooks() {
        Map<String, byte[]> entries = new LinkedHashMap<>();
        entries.put("word/document.xml", new byte[8]);
        assertThatThrownBy(() -> ZipSafety.inspectSpreadsheet(DocumentReaderTestSupport.zip(entries)))
                .isInstanceOf(ApiException.class).hasMessageContaining("缺少");
        assertThatThrownBy(() -> ZipSafety.inspectSpreadsheet("not a zip".getBytes(StandardCharsets.UTF_8)))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void rejectsTooManyEntries() {
        Map<String, byte[]> entries = minimal();
        for (int i = 0; i < ZipSafety.MAX_ENTRIES + 1; i++) {
            entries.put("xl/media/i" + i + ".png", new byte[1]);
        }
        assertThatThrownBy(() -> ZipSafety.inspectSpreadsheet(DocumentReaderTestSupport.zip(entries)))
                .isInstanceOf(ApiException.class);
    }
}
