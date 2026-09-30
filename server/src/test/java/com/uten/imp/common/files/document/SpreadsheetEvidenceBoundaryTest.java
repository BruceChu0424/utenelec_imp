package com.uten.imp.common.files.document;

import org.junit.jupiter.api.Test;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;
import static org.assertj.core.api.Assertions.*;

class SpreadsheetEvidenceBoundaryTest {
    @Test void externalMetadataIsOnlyAllowedByExplicitReadOnlyEvidenceBoundary() throws Exception {
        byte[] bytes = archive("xl/externalLinks/externalLink1.xml");
        assertThatThrownBy(() -> ZipSafety.inspectSpreadsheet(bytes)).hasMessageContaining("外部链接");
        assertThat(ZipSafety.inspectSpreadsheetEvidence(bytes)).contains("xl/externalLinks/externalLink1.xml");
    }
    @Test void evidencePathDoesNotAdmitMacrosOrOleObjects() throws Exception {
        for (String path : java.util.List.of("xl/vbaProject.bin", "xl/embeddings/oleObject1.bin")) {
            byte[] bytes = archive(path);
            assertThatThrownBy(() -> ZipSafety.inspectSpreadsheetEvidence(bytes)).hasMessageContaining("宏");
        }
    }
    private static byte[] archive(String extra) throws Exception {
        try (var out = new ByteArrayOutputStream(); var zip = new ZipOutputStream(out)) {
            for (String name : java.util.List.of("[Content_Types].xml", "xl/workbook.xml", extra)) {
                zip.putNextEntry(new ZipEntry(name)); zip.write("<root/>".getBytes(StandardCharsets.UTF_8)); zip.closeEntry();
            }
            zip.finish(); return out.toByteArray();
        }
    }
}
