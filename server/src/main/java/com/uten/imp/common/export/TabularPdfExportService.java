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
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
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
        validatePassword(password);
        Path root=null;
        try {
            root=Files.createTempDirectory("uten-pdf-sync-");
            try(var writer=openDocumentStream(root,password);var bytes=new ByteArrayOutputStream()) {
                DocumentPageSink.emitDocument(document,writer);
                writer.finish(bytes);
                return bytes.toByteArray();
            }
        } catch (IOException failure) {
            throw new IllegalStateException("生成成本 PDF 失败", failure);
        } finally {
            if(root!=null)try{Files.deleteIfExists(root);}catch(IOException ignored){}
        }
    }

    public StreamingDocumentWriter openDocumentStream(Path privateDirectory) {return openDocumentStream(privateDirectory,null);}
    public StreamingDocumentWriter openDocumentStream(Path privateDirectory,String password) {
        validatePassword(password);
        try{return new StreamingPdfDocumentWriter(privateDirectory,password);}
        catch(IOException failure){throw new java.io.UncheckedIOException(failure);}
    }
    static void validatePassword(String password) {
        if(password!=null&&password.length()>128)throw new IllegalArgumentException("导出密码长度不能超过 128 位");
    }
    static void protectDocument(PDDocument pdf,String password)throws IOException {
        if(password==null||password.isEmpty())return;
        var policy=new StandardProtectionPolicy(UUID.randomUUID().toString(),password,new AccessPermission());
        policy.setEncryptionKeyLength(256);policy.setPreferAES(true);pdf.protect(policy);
    }

    /** Private disk copy for a single authorized download; passwords are never persisted. */
    public void protect(Path source,Path target,String password)throws IOException {
        validatePassword(password);
        LegacyExportBudget.checkpoint();
        if(!Files.isRegularFile(source,LinkOption.NOFOLLOW_LINKS)||Files.isSymbolicLink(source))throw new IOException("Invalid PDF source");
        long sourceBytes=Files.size(source);
        if(sourceBytes>ExportResourceLimits.ARTIFACT_BYTES)throw new IOException("Export file size limit exceeded");
        Path parent=target.toAbsolutePath().getParent();
        if(Files.getFileStore(parent).getUsableSpace()<ExportResourceLimits.FREE_RESERVE_BYTES+sourceBytes+1024*1024)
            throw new IOException("Export free space reserve reached");
        Path scratch=null;boolean created=false,complete=false;
        try {
            if(password==null||password.isEmpty()) {
                try(var file=Files.newOutputStream(target,StandardOpenOption.CREATE_NEW,StandardOpenOption.WRITE)) {
                    created=true;
                    try(var input=Files.newInputStream(source)) {
                        input.transferTo(ExportTemporaryBudget.artifactOutput(file,parent,LegacyExportBudget::checkpoint));
                    }
                }
            } else {
                scratch=StreamingPdfDocumentWriter.privateDirectory(parent,"report-download-pdf-");
                Path cache=scratch;
                try(var pdf=org.apache.pdfbox.Loader.loadPDF(source.toFile(),()->new org.apache.pdfbox.io.ScratchFile(
                        org.apache.pdfbox.io.MemoryUsageSetting.setupTempFileOnly(ExportResourceLimits.SHEET_TEMP_BYTES).setTempDir(cache.toFile())))) {
                    if(pdf.getNumberOfPages()>250)throw new IOException("PDF page limit exceeded");
                    protectDocument(pdf,password);
                    try(var file=Files.newOutputStream(target,StandardOpenOption.CREATE_NEW,StandardOpenOption.WRITE)) {
                        created=true;pdf.save(ExportTemporaryBudget.artifactOutput(file,parent,LegacyExportBudget::checkpoint));
                    }
                }
            }
            complete=true;
        }finally{
            if(created&&!complete)Files.deleteIfExists(target);
            if(scratch!=null)StreamingPdfDocumentWriter.removePrivateDirectory(scratch);
        }
    }

    interface RowCursor extends AutoCloseable {
        Map<String,Object> next()throws IOException;
        @Override void close()throws IOException;
    }
    interface RowSource {
        String name();List<ExportColumn> columns();RowCursor open()throws IOException;
    }
    static RowSource memorySection(ExportDocument.Section section) {
        return new RowSource() {
            @Override
            public String name(){return section.name();}@Override public List<ExportColumn> columns(){return section.columns();}
            @Override
            public RowCursor open(){var rows=section.rows().iterator();return new RowCursor(){
                @Override
                public Map<String,Object> next(){return rows.hasNext()?rows.next():null;}@Override public void close(){}
            };}
        };
    }

    static void renderSection(PDDocument pdf, PDType0Font font, String title,
                                      RowSource section,Runnable checkpoint) throws IOException {
        float[] desired = new float[section.columns().size()];
        boolean repeatIdentity = !isNumeric(section.columns().getFirst());
        for (int i = 0; i < desired.length; i++) {
            desired[i]=width(font,clean(section.columns().get(i).label()),FONT_SIZE)+16;
        }
        try(var rows=section.open()) {
            Map<String,Object> values;
            while((values=rows.next())!=null) {
                checkpoint.run();
                for(int i=0;i<desired.length;i++)desired[i]=Math.max(desired[i],width(font,clean(ExportCellValues.display(section.columns().get(i),values)),FONT_SIZE)+16);
            }
        }
        for(int i=0;i<desired.length;i++) {
            ExportColumn column=section.columns().get(i);
            float limit = desired.length == 1 ? WIDTH : isNumeric(column)
                    ? WIDTH - (repeatIdentity && i > 0 ? desired[0] : 0) : 240;
            desired[i] = Math.min(limit, Math.max(66, desired[i]));
        }
        List<List<Integer>> panels = panels(desired, repeatIdentity);
        for (int group = 0; group < panels.size(); group++) {
            List<Integer> columns = panels.get(group);
            float total = 0;
            for (int c : columns) total += desired[c];
            float stretch = WIDTH / total;
            float[] widths = new float[columns.size()];
            for (int c = 0; c < columns.size(); c++) widths[c] = desired[columns.get(c)] * stretch;
            try(var rows=section.open()) {
            Map<String,Object> values=rows.next();
            do {
                checkpoint.run();
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
                    while (values!=null && y > MARGIN + 30) {
                        checkpoint.run();
                        Map<String,Object> current=values;
                        List<String> cells = columns.stream().map(c -> ExportCellValues.display(section.columns().get(c),current)).toList();
                        List<Boolean> numbers = columns.stream().map(c -> isNumeric(section.columns().get(c))).toList();
                        row(stream, font, cells, numbers, widths, y, false);
                        y -= ROW;
                        values=rows.next();
                    }
                    text(stream, font, "第 " + pdf.getNumberOfPages() + " 页 - " + section.name(), MARGIN,
                            MARGIN - 1, 8, WIDTH, false);
                }
            } while (values!=null);
            }
        }
    }

    /** Wide tables repeat the first identity column rather than shrinking type to illegibility. */
    private static List<List<Integer>> panels(float[] widths, boolean repeatIdentity) {
        List<List<Integer>> result = new ArrayList<>();
        int next = 0;
        while (next < widths.length) {
            int before=next;
            List<Integer> panel = new ArrayList<>();
            float used = 0;
            if (next > 0 && repeatIdentity) { panel.add(0); used = widths[0]; }
            while (next < widths.length && (panel.isEmpty() || used + widths[next] <= WIDTH)) {
                panel.add(next); used += widths[next++];
            }
            // Floating point or an exceptionally wide column must never leave the iterator stationary.
            if(next==before)panel.add(next++);
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
