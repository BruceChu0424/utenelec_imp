package com.uten.imp.features.ai.job;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class AiJobUploadTest {

    private static byte[] bytes(int... values) {
        byte[] result = new byte[values.length + 16];
        for (int i = 0; i < values.length; i++) {
            result[i] = (byte) values[i];
        }
        return result;
    }

    @Test
    void sniffsByMagicBytesAndExtension() {
        assertThat(AiJobUpload.sniff(bytes(0x50, 0x4B, 0x03, 0x04), "SUNAS.xlsx")).isEqualTo("XLSX");
        assertThat(AiJobUpload.sniff(bytes(0x50, 0x4B, 0x03, 0x04), "archive.zip")).isEqualTo("UNSUPPORTED");
        assertThat(AiJobUpload.sniff(bytes(0x50, 0x4B, 0x03, 0x04), "macro.xlsm")).isEqualTo("UNSUPPORTED");
        assertThat(AiJobUpload.sniff(bytes(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1), "old.XLS"))
                .isEqualTo("XLS");
        assertThat(AiJobUpload.sniff(bytes(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1), "letter.doc"))
                .isEqualTo("UNSUPPORTED");
        assertThat(AiJobUpload.sniff("%PDF-1.7".getBytes(StandardCharsets.US_ASCII), "pi.bin")).isEqualTo("PDF");
        assertThat(AiJobUpload.sniff(bytes(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A), "x")).isEqualTo("PNG");
        assertThat(AiJobUpload.sniff(bytes(0xFF, 0xD8, 0xFF, 0xE0), "photo.jpg")).isEqualTo("JPEG");
        assertThat(AiJobUpload.sniff("RIFF1234WEBPVP8 ".getBytes(StandardCharsets.US_ASCII), "a.webp"))
                .isEqualTo("WEBP");
        assertThat(AiJobUpload.sniff("model,qty\nGZ23,10\n".getBytes(StandardCharsets.UTF_8), "list.csv"))
                .isEqualTo("CSV");
        assertThat(AiJobUpload.sniff(new byte[]{'a', 0, 'b'}, "binary.csv")).isEqualTo("UNSUPPORTED");
        assertThat(AiJobUpload.sniff("model,qty".getBytes(StandardCharsets.UTF_8), "list.exe"))
                .isEqualTo("UNSUPPORTED");
        assertThat(AiJobUpload.sniff(new byte[0], "empty.csv")).isEqualTo("UNSUPPORTED");
    }

    @Test
    void readsWithinTheLimitAndStopsAtTheFirstByteBeyondIt() throws Exception {
        byte[] content = "hello".getBytes(StandardCharsets.UTF_8);
        assertThat(AiJobUpload.readBounded(new ByteArrayInputStream(content), -1, 5)).isEqualTo(content);

        assertThatThrownBy(() -> AiJobUpload.readBounded(new ByteArrayInputStream(new byte[6]), -1, 5))
                .isInstanceOf(ApiException.class)
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.PAYLOAD_TOO_LARGE);
        InputStream never = new InputStream() {
            @Override
            public int read() {
                throw new AssertionError("declared length above the limit must be rejected before reading");
            }
        };
        assertThatThrownBy(() -> AiJobUpload.readBounded(never, 20L * 1024 * 1024, 15L * 1024 * 1024))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("15 MB");
        assertThatThrownBy(() -> AiJobUpload.readBounded(new ByteArrayInputStream(new byte[0]), 0, 5))
                .isInstanceOf(ApiException.class)
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
    }

    @Test
    void cleansFileNamesAndContentTypes() {
        // 客户文件名常带全角括号(U+FF08/U+FF09), 百分号解码后原样保留。
        assertThat(AiJobUpload.fileName("SUNAS%EF%BC%882026-1-19%EF%BC%89.xlsx"))
                .isEqualTo("SUNAS\uFF082026-1-19\uFF09.xlsx");
        assertThat(AiJobUpload.fileName("..%2F..%2Fetc%2Fpasswd")).isEqualTo("passwd");
        assertThat(AiJobUpload.fileName("C%3A%5CUsers%5Cme%5Cquote+1.xlsx")).isEqualTo("quote+1.xlsx");
        assertThat(AiJobUpload.fileName("bad%ZZname")).isEqualTo("upload");
        assertThat(AiJobUpload.fileName(null)).isEqualTo("upload");
        assertThat(AiJobUpload.fileName("a%0Ab%00c.csv")).isEqualTo("abc.csv");
        assertThat(AiJobUpload.fileName("x".repeat(300) + ".xlsx")).hasSize(255).endsWith(".xlsx");

        assertThat(AiJobUpload.contentType("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"))
                .isEqualTo("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
        assertThat(AiJobUpload.contentType("text/csv; charset=utf-8")).isEqualTo("text/csv");
        assertThat(AiJobUpload.contentType("<script>")).isEqualTo("application/octet-stream");
        assertThat(AiJobUpload.contentType(null)).isEqualTo("application/octet-stream");
    }
}
