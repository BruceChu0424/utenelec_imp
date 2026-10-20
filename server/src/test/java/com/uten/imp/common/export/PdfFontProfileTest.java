package com.uten.imp.common.export;

import ch.qos.logback.classic.Level;
import ch.qos.logback.classic.Logger;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.read.ListAppender;
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.pdmodel.encryption.InvalidPasswordException;
import org.apache.pdfbox.rendering.PDFRenderer;
import org.apache.pdfbox.text.PDFTextStripper;
import org.junit.jupiter.api.Test;
import org.slf4j.LoggerFactory;

import java.math.BigDecimal;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class PdfFontProfileTest {
    private record Table(int offset, int length) { }
    private record CmapKey(int platform, int encoding, int format) { }

    @Test
    void fullGlyphProfilePreservesAllSupportedMapsOutlinesMetricsAndLicensing() throws Exception {
        byte[] source = Files.readAllBytes(Path.of("../assets/fonts/NotoSansSCFull.ttf"));
        byte[] profile;
        try (var stream = Objects.requireNonNull(getClass().getResourceAsStream("/fonts/NotoSansSCFullPdf.ttf"))) {
            profile = stream.readAllBytes();
        }
        assertThat(sha256(source)).isEqualTo("a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da");
        assertThat(sha256(profile)).isEqualTo("9b8c800a3327f95133d67303017ae242c02097648c9cc73832a2b7d60cd16bc0");
        assertThat(profile).hasSameSizeAs(source);
        assertThat(checksum(source)).isEqualTo(0xB1B0AFBAL);
        assertThat(checksum(profile)).isEqualTo(0xB1B0AFBAL);

        Map<String, Table> originalTables = directory(source);
        Map<String, Table> profileTables = directory(profile);
        assertThat(profileTables.keySet()).containsExactlyInAnyOrderElementsOf(originalTables.keySet());
        for (var entry : originalTables.entrySet()) {
            String tag = entry.getKey();
            if ("cmap".equals(tag)) continue;
            assertThat(profileTables.get(tag)).as("original table offset/length: %s", tag).isEqualTo(entry.getValue());
            byte[] before = table(source, entry.getValue());
            byte[] after = table(profile, profileTables.get(tag));
            if ("head".equals(tag)) {
                // Only the whole-font checksum adjustment may change.
                Arrays.fill(before, 8, 12, (byte) 0);
                Arrays.fill(after, 8, 12, (byte) 0);
            }
            assertThat(after).as("complete original table: %s", tag).isEqualTo(before);
        }
        assertThat(unsignedShort(table(profile, profileTables.get("maxp")), 4)).isEqualTo(31_036);

        var beforeMaps = new LinkedHashMap<>(cmapRecords(table(source, originalTables.get("cmap"))));
        var afterMaps = cmapRecords(table(profile, profileTables.get("cmap")));
        byte[] removed = beforeMaps.remove(new CmapKey(0, 5, 14));
        assertThat(removed).hasSize(147);
        assertThat(afterMaps).hasSize(5);
        assertThat(afterMaps.keySet()).containsExactlyInAnyOrderElementsOf(beforeMaps.keySet());
        for (var entry : beforeMaps.entrySet()) {
            assertThat(afterMaps.get(entry.getKey())).as("complete supported cmap: %s", entry.getKey()).isEqualTo(entry.getValue());
        }
        Map<Integer, Integer> base = unicodeMappings(beforeMaps.get(new CmapKey(3, 10, 12)));
        assertThat(base).hasSize(30_890);
        assertThat(unicodeMappings(afterMaps.get(new CmapKey(3, 10, 12)))).isEqualTo(base);
        assertThat(base.keySet().stream().filter(point -> point > 0xFFFF).count()).isEqualTo(445);
        assertThat(base.keySet().stream().filter(point -> point >= 0x20000 && point <= 0x323AF).count()).isEqualTo(220);
        for (int point : "中文龘䶮㐂\uD840\uDC87".codePoints().toArray()) {
            assertThat(base.get(point)).as("original CJK glyph U+%X", point).isPositive();
        }
        try (var license = Objects.requireNonNull(getClass().getResourceAsStream("/fonts/OFL.txt"))) {
            assertThat(new String(license.readAllBytes(), StandardCharsets.UTF_8))
                    .contains("SIL OPEN FONT LICENSE Version 1.1", "Reserved Font Name");
        }
    }

    @Test
    void realChineseSupplementaryGlyphsExactAmountsAndEncryptionProduceNoFontBoxWarning() throws Exception {
        Logger fontbox = (Logger) LoggerFactory.getLogger("org.apache.fontbox");
        var captured = new ListAppender<ILoggingEvent>();
        captured.start();
        fontbox.addAppender(captured);
        try {
            String rare = "中文龘䶮㐂\uD840\uDC87";
            String exact = "1234567890123456.00000000007";
            var document = new ExportDocument("完整字形与金额验证", List.of("原始完整字体的PDF兼容profile"), List.of(
                    new ExportDocument.Section("稀有汉字", List.of(
                            new ExportColumn("name", "原始字形", ExportColumn.TEXT),
                            new ExportColumn("amount", "精确金额", ExportColumn.MONEY)),
                            List.of(Map.of("name", rare, "amount", new BigDecimal(exact))))));
            var service = new TabularPdfExportService();
            byte[] bytes = service.build(document, null);
            try (var pdf = Loader.loadPDF(bytes)) {
                assertThat(new PDFTextStripper().getText(pdf)).contains(rare, exact).doesNotContain("...");
                var page = pdf.getPage(pdf.getNumberOfPages() - 1);
                for (var name : page.getResources().getFontNames()) {
                    assertThat(page.getResources().getFont(name).isEmbedded()).isTrue();
                }
                var rendered = new PDFRenderer(pdf).renderImageWithDPI(pdf.getNumberOfPages() - 1, 140);
                assertThat(rendered.getWidth()).isGreaterThan(1_000);
                assertThat(rendered.getHeight()).isGreaterThan(500);
                String qa = System.getProperty("uten.pdf.font.qa");
                if (qa != null && !qa.isBlank()) {
                    Path directory = Path.of(qa).toAbsolutePath();
                    Files.createDirectories(directory);
                    Files.write(directory.resolve("pdf-font-profile-sample.pdf"), bytes);
                    javax.imageio.ImageIO.write(rendered, "png", directory.resolve("pdf-font-profile-page.png").toFile());
                }
            }
            byte[] encrypted = service.build(document, "test-only-font-profile-password");
            assertThatThrownBy(() -> Loader.loadPDF(encrypted)).isInstanceOf(InvalidPasswordException.class);
            try (var pdf = Loader.loadPDF(encrypted, "test-only-font-profile-password")) {
                assertThat(pdf.isEncrypted()).isTrue();
                assertThat(new PDFTextStripper().getText(pdf)).contains(rare, exact);
            }
            // Capture the entire FontBox namespace without changing its level,
            // appenders, additivity or filters; any real WARN/ERROR fails.
            assertThat(captured.list.stream().filter(event -> event.getLevel().isGreaterOrEqual(Level.WARN))
                    .map(ILoggingEvent::getFormattedMessage).toList()).isEmpty();
        } finally {
            fontbox.detachAppender(captured);
            captured.stop();
        }
    }

    private static Map<String, Table> directory(byte[] font) {
        int count = unsignedShort(font, 4);
        Map<String, Table> result = new LinkedHashMap<>();
        for (int index = 0; index < count; index++) {
            int entry = 12 + 16 * index;
            String tag = new String(font, entry, 4, StandardCharsets.US_ASCII);
            var record = ByteBuffer.wrap(font, entry + 8, 8);
            result.put(tag, new Table(record.getInt(), record.getInt()));
        }
        return Map.copyOf(result);
    }

    private static byte[] table(byte[] font, Table table) {
        Objects.requireNonNull(table, "required sfnt table");
        return Arrays.copyOfRange(font, table.offset(), table.offset() + table.length());
    }

    private static Map<CmapKey, byte[]> cmapRecords(byte[] cmap) {
        Map<CmapKey, byte[]> result = new LinkedHashMap<>();
        int count = unsignedShort(cmap, 2);
        for (int index = 0; index < count; index++) {
            var record = ByteBuffer.wrap(cmap, 4 + index * 8, 8);
            int platform = Short.toUnsignedInt(record.getShort());
            int encoding = Short.toUnsignedInt(record.getShort());
            int offset = record.getInt();
            int form = unsignedShort(cmap, offset);
            int length = switch (form) {
                case 0, 2, 4, 6 -> unsignedShort(cmap, offset + 2);
                case 8, 10, 12, 13 -> ByteBuffer.wrap(cmap, offset + 4, 4).getInt();
                case 14 -> ByteBuffer.wrap(cmap, offset + 2, 4).getInt();
                default -> throw new IllegalArgumentException("unexpected cmap format " + form);
            };
            result.put(new CmapKey(platform, encoding, form), Arrays.copyOfRange(cmap, offset, offset + length));
        }
        return Map.copyOf(result);
    }

    private static Map<Integer, Integer> unicodeMappings(byte[] subtable) {
        Objects.requireNonNull(subtable, "full Unicode cmap is required");
        assertThat(unsignedShort(subtable, 0)).isEqualTo(12);
        int groups = ByteBuffer.wrap(subtable, 12, 4).getInt();
        Map<Integer, Integer> result = new LinkedHashMap<>();
        for (int index = 0; index < groups; index++) {
            var group = ByteBuffer.wrap(subtable, 16 + index * 12, 12);
            int start = group.getInt();
            int end = group.getInt();
            int firstGlyph = group.getInt();
            if (start < 0 || end < start || end > Character.MAX_CODE_POINT || firstGlyph < 0
                    || (long) firstGlyph + end - start > 0xFFFF) {
                throw new IllegalArgumentException("invalid Unicode cmap group");
            }
            for (int point = start; point <= end; point++) {
                int glyph = firstGlyph + point - start;
                if (glyph != 0) result.put(point, glyph);
            }
        }
        return Map.copyOf(result);
    }

    private static int unsignedShort(byte[] data, int offset) {
        return Short.toUnsignedInt(ByteBuffer.wrap(data, offset, 2).getShort());
    }

    private static String sha256(byte[] data) throws Exception {
        return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(data));
    }

    private static long checksum(byte[] data) {
        var words = ByteBuffer.wrap(Arrays.copyOf(data, (data.length + 3) & ~3));
        long result = 0;
        while (words.hasRemaining()) result = (result + Integer.toUnsignedLong(words.getInt())) & 0xFFFFFFFFL;
        return result;
    }
}
