package com.uten.imp.common.export;

import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PDPage;
import org.apache.pdfbox.pdmodel.PDPageContentStream;
import org.apache.pdfbox.pdmodel.common.PDRectangle;
import org.apache.pdfbox.pdmodel.encryption.AccessPermission;
import org.apache.pdfbox.pdmodel.encryption.StandardProtectionPolicy;
import org.apache.pdfbox.pdmodel.font.PDType0Font;
import org.springframework.stereotype.Service;

import java.awt.Color;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/** Paginated, embedded-CJK PDF output for the same authorized snapshot as Excel. */
@Service
public class TabularPdfExportService {
    private static final float MARGIN = 26;
    private static final float ROW = 24;
    private static final float FONT_SIZE = 8.5f;
    private static final PDRectangle PAPER = new PDRectangle(PDRectangle.A4.getHeight(), PDRectangle.A4.getWidth());
    private static final float WIDTH = PAPER.getWidth() - 2 * MARGIN;
    private static final Color INK = new Color(32, 48, 43);
    private static final Color LINE = new Color(217, 225, 220);
    private static final Color HEADER = new Color(234, 242, 237);

    public byte[] build(ExportDocument document, String password) {
        if (password != null && password.length() > 128) throw new IllegalArgumentException("导出密码长度不能超过 128 位");
        long cells = document.sections().stream().mapToLong(s -> (long) s.columns().size() * s.rows().size()).sum();
        if (cells > 60_000) throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,
                "PDF 明细较多，请缩小范围或下载 Excel");
        try (PDDocument pdf = new PDDocument();
             var fontFile = getClass().getResourceAsStream("/fonts/NotoSansSCFull.ttf");
             ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
            if (fontFile == null) throw new IllegalStateException("导出中文字体资源缺失");
            PDType0Font font = PDType0Font.load(pdf, fontFile, true);
            pdf.getDocumentInformation().setTitle(document.title());
            pdf.getDocumentInformation().setProducer("Uten IMP");
            var metadata = document.metadata().stream().map(value -> Map.<String, Object>of("value", value)).toList();
            renderSection(pdf, font, document.title(), new ExportDocument.Section("版本与口径",
                    List.of(new ExportColumn("value", "来源说明", ExportColumn.TEXT, (double) WIDTH)), metadata));
            for (ExportDocument.Section section : document.sections()) renderSection(pdf, font, document.title(), section);
            if (password != null && !password.isEmpty()) {
                var policy = new StandardProtectionPolicy(UUID.randomUUID().toString(), password, new AccessPermission());
                policy.setEncryptionKeyLength(256);
                policy.setPreferAES(true);
                pdf.protect(policy);
            }
            pdf.save(bytes);
            return bytes.toByteArray();
        } catch (IOException failure) {
            throw new IllegalStateException("生成成本 PDF 失败", failure);
        }
    }

    private static void renderSection(PDDocument pdf, PDType0Font font, String title,
                                      ExportDocument.Section section) throws IOException {
        float[] desired = new float[section.columns().size()];
        boolean repeatIdentity = !isNumeric(section.columns().getFirst());
        for (int i = 0; i < desired.length; i++) {
            ExportColumn column = section.columns().get(i);
            float max = width(font, clean(column.label()), FONT_SIZE) + 16;
            for (Map<String, Object> row : section.rows()) max = Math.max(max,
                    width(font, clean(value(row.get(column.key()))), FONT_SIZE) + 16);
            float limit = desired.length == 1 ? WIDTH : isNumeric(column)
                    ? WIDTH - (repeatIdentity && i > 0 ? desired[0] : 0) : 240;
            desired[i] = Math.min(limit, Math.max(66, max));
        }
        List<List<Integer>> panels = panels(desired, repeatIdentity);
        for (int group = 0; group < panels.size(); group++) {
            List<Integer> columns = panels.get(group);
            float total = 0;
            for (int c : columns) total += desired[c];
            float stretch = WIDTH / total;
            float[] widths = new float[columns.size()];
            for (int c = 0; c < columns.size(); c++) widths[c] = desired[columns.get(c)] * stretch;
            int offset = 0;
            do {
                if (pdf.getNumberOfPages() >= 250) throw new com.uten.imp.common.web.ApiException(
                        com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED, "PDF 超过 250 页，请缩小范围或下载 Excel");
                PDPage page = new PDPage(PAPER);
                pdf.addPage(page);
                try (PDPageContentStream stream = new PDPageContentStream(pdf, page)) {
                    text(stream, font, title, MARGIN, PAPER.getHeight() - MARGIN - 12, 13, WIDTH, false);
                    String sectionTitle = section.name() + (panels.size() > 1 ? " - 列组 " + (group + 1) + "/" + panels.size() : "");
                    text(stream, font, sectionTitle, MARGIN, PAPER.getHeight() - MARGIN - 35, 10, WIDTH, false);
                    float y = PAPER.getHeight() - MARGIN - 48;
                    row(stream, font, columns.stream().map(c -> section.columns().get(c).label()).toList(),
                            null, widths, y, true);
                    y -= ROW;
                    while (offset < section.rows().size() && y > MARGIN + 30) {
                        Map<String, Object> row = section.rows().get(offset++);
                        List<String> cells = columns.stream().map(c -> value(row.get(section.columns().get(c).key()))).toList();
                        List<Boolean> numbers = columns.stream().map(c -> isNumeric(section.columns().get(c))).toList();
                        row(stream, font, cells, numbers, widths, y, false);
                        y -= ROW;
                    }
                    text(stream, font, "第 " + pdf.getNumberOfPages() + " 页 - " + section.name(), MARGIN,
                            MARGIN - 1, 8, WIDTH, false);
                }
            } while (offset < section.rows().size());
        }
    }

    /** Wide tables repeat the first identity column rather than shrinking type to illegibility. */
    private static List<List<Integer>> panels(float[] widths, boolean repeatIdentity) {
        List<List<Integer>> result = new ArrayList<>();
        int next = 0;
        while (next < widths.length) {
            List<Integer> panel = new ArrayList<>();
            float used = 0;
            if (next > 0 && repeatIdentity) { panel.add(0); used = widths[0]; }
            while (next < widths.length && (panel.isEmpty() || used + widths[next] <= WIDTH)) {
                panel.add(next); used += widths[next++];
            }
            // Every individual column is capped below WIDTH - identity width.
            result.add(List.copyOf(panel));
        }
        return result;
    }

    private static void row(PDPageContentStream stream, PDType0Font font, List<String> values,
                            List<Boolean> numeric, float[] widths, float top, boolean header) throws IOException {
        if (header) {
            stream.setNonStrokingColor(HEADER);
            stream.addRect(MARGIN, top - ROW, WIDTH, ROW);
            stream.fill();
        }
        float x = MARGIN;
        for (int c = 0; c < values.size(); c++) {
            text(stream, font, values.get(c), x + 6, top - 16, FONT_SIZE, widths[c] - 12,
                    !header && numeric != null && numeric.get(c));
            x += widths[c];
        }
        stream.setStrokingColor(LINE);
        stream.setLineWidth(.35f);
        stream.moveTo(MARGIN, top - ROW);
        stream.lineTo(MARGIN + WIDTH, top - ROW);
        stream.stroke();
    }

    private static void text(PDPageContentStream stream, PDType0Font font, String raw, float x, float y,
                             float size, float maxWidth, boolean right) throws IOException {
        String value = clean(raw);
        if (right && width(font, value, size) > maxWidth) {
            // An ellipsis in a money/quantity cell changes its meaning. Refuse a misleading PDF.
            throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,
                    "精确金额或数量过长，PDF 无法完整显示，请下载 Excel 精确文本");
        }
        if (width(font, value, size) > maxWidth) {
            int end = value.length();
            while (end > 0 && width(font, value.substring(0, end) + "...", size) > maxWidth)
                end = value.offsetByCodePoints(end, -1);
            value = value.substring(0, end) + "...";
        }
        stream.setNonStrokingColor(INK);
        stream.beginText();
        stream.setFont(font, size);
        stream.newLineAtOffset(right ? x + maxWidth - width(font, value, size) : x, y);
        stream.showText(value);
        stream.endText();
    }

    private static float width(PDType0Font font, String text, float size) throws IOException {
        return font.getStringWidth(text) * size / 1000;
    }
    private static String value(Object value) {
        return value == null ? "—" : value instanceof BigDecimal number ? number.toPlainString() : Objects.toString(value);
    }
    private static String clean(String value) { return value == null ? "" : value.replaceAll("[\\p{Cntrl}\\r\\n]+", " "); }
    private static boolean isNumeric(ExportColumn column) {
        return ExportColumn.MONEY.equals(column.type()) || ExportColumn.NUMBER.equals(column.type()) || ExportColumn.QTY.equals(column.type());
    }
}
