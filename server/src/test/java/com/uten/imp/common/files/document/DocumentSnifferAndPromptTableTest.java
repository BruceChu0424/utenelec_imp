package com.uten.imp.common.files.document;

import com.uten.imp.common.files.document.DocumentGrid.Cell;
import com.uten.imp.common.files.document.DocumentGrid.Row;
import com.uten.imp.common.files.document.DocumentGrid.Sheet;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class DocumentSnifferAndPromptTableTest {

    @Test
    void sniffsByMagicBytesNotByClaimedName() {
        byte[] png = {(byte) 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0};
        byte[] jpeg = {(byte) 0xFF, (byte) 0xD8, (byte) 0xFF, (byte) 0xE0};
        byte[] webp = "RIFF\0\0\0\0WEBPVP8 ".getBytes(StandardCharsets.ISO_8859_1);
        byte[] zip = {'P', 'K', 3, 4, 0, 0};
        byte[] ole = {(byte) 0xD0, (byte) 0xCF, 0x11, (byte) 0xE0, (byte) 0xA1, (byte) 0xB1, 0x1A, (byte) 0xE1};
        assertThat(DocumentSniffer.sniff(png, "quote.xlsx")).isEqualTo(DocumentKind.PNG);
        assertThat(DocumentSniffer.sniff(jpeg, "a.jpg")).isEqualTo(DocumentKind.JPEG);
        assertThat(DocumentSniffer.sniff(webp, "a.webp")).isEqualTo(DocumentKind.WEBP);
        assertThat(DocumentSniffer.sniff("%PDF-1.7".getBytes(), "x.bin")).isEqualTo(DocumentKind.PDF);
        assertThat(DocumentSniffer.sniff(zip, "Quote.XLSX")).isEqualTo(DocumentKind.XLSX);
        assertThat(DocumentSniffer.sniff(zip, "macro.xlsm")).isEqualTo(DocumentKind.UNSUPPORTED);
        assertThat(DocumentSniffer.sniff(zip, "doc.docx")).isEqualTo(DocumentKind.UNSUPPORTED);
        assertThat(DocumentSniffer.sniff(ole, "old.xls")).isEqualTo(DocumentKind.XLS);
        assertThat(DocumentSniffer.sniff(ole, "report.doc")).isEqualTo(DocumentKind.UNSUPPORTED);
        assertThat(DocumentSniffer.sniff("a,b\n1,2".getBytes(), "list.csv")).isEqualTo(DocumentKind.CSV);
        assertThat(DocumentSniffer.sniff("型号,数量".getBytes(Charset.forName("GBK")), "list.csv")).isEqualTo(DocumentKind.CSV);
        assertThat(DocumentSniffer.sniff(new byte[]{1, 0, 2}, "bin.csv")).isEqualTo(DocumentKind.UNSUPPORTED);
        assertThat(DocumentSniffer.sniff("a,b".getBytes(), "script.js")).isEqualTo(DocumentKind.UNSUPPORTED);
        assertThat(DocumentSniffer.sniff(new byte[0], "x.csv")).isEqualTo(DocumentKind.UNSUPPORTED);
    }

    @Test
    void boundedReaderStopsAtTheLimit() throws IOException {
        byte[] data = new byte[1000];
        assertThat(BoundedBodyReader.read(new ByteArrayInputStream(data), 1000)).hasSize(1000);
        assertThatThrownBy(() -> BoundedBodyReader.read(new ByteArrayInputStream(data), 999))
                .isInstanceOf(ApiException.class)
                .satisfies(e -> assertThat(((ApiException) e).getCode()).isEqualTo(ErrorCode.PAYLOAD_TOO_LARGE));
        assertThatThrownBy(() -> BoundedBodyReader.read(new ByteArrayInputStream(data), 5_000_000, 1000))
                .isInstanceOf(ApiException.class);
    }

    private static Sheet sheet() {
        return new Sheet("S", 0, List.of(
                new Row(0, List.of(Cell.text(0, "Buyer: DELTA"))),
                new Row(9, List.of(Cell.text(0, "S/N"), Cell.text(1, "Part No.\n零配件编号"))),
                new Row(10, List.of(Cell.text(0, "1"), Cell.text(1, "K20AD-01"), Cell.text(2, "x".repeat(300)))),
                new Row(11, List.of(Cell.text(0, "Bank: EXAMPLE"), Cell.text(1, "Swift: EXAMPLEXX")))),
                List.of(), 0, 2, false);
    }

    @Test
    void promptTableUsesRowNumbersAndColumnLetters() {
        String out = PromptTable.render(sheet(), 0, 20, 10_000, Set.of(11));
        assertThat(out).contains("R1 | A:Buyer: DELTA")
                .contains("R10 | A:S/N | B:Part No. / 零配件编号")
                .contains("R11 | A:1 | B:K20AD-01 | C:" + "x".repeat(200) + "...")
                .doesNotContain("Swift").doesNotContain("Bank");
    }

    @Test
    void promptTableTruncatesWithMarker() {
        String out = PromptTable.render(sheet(), 0, 20, 60, null);
        assertThat(out).endsWith(PromptTable.TRUNCATION_MARKER);
        assertThat(out).contains("R1 | A:Buyer: DELTA");
    }

    @Test
    void imageGuardChecksSizeAndDimensions() {
        byte[] png = new byte[33];
        byte[] header = {(byte) 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 1, 0, 0, 0, 1, 0};
        System.arraycopy(header, 0, png, 0, header.length);
        DocumentImageGuard.requireSafe(png, DocumentKind.PNG);
        byte[] huge = header.clone();
        huge[16] = 0x7F;
        byte[] hugeFull = new byte[33];
        System.arraycopy(huge, 0, hugeFull, 0, huge.length);
        assertThatThrownBy(() -> DocumentImageGuard.requireSafe(hugeFull, DocumentKind.PNG)).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> DocumentImageGuard.requireSafe(new byte[(int) DocumentImageGuard.MAX_IMAGE_BYTES + 1],
                DocumentKind.PNG)).isInstanceOf(ApiException.class);
    }
}
