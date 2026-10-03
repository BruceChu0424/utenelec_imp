package com.uten.imp.common.files.document;

import com.uten.imp.common.web.ApiException;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PDPage;
import org.apache.pdfbox.pdmodel.PDPageContentStream;
import org.apache.pdfbox.pdmodel.common.PDRectangle;
import org.apache.pdfbox.pdmodel.encryption.AccessPermission;
import org.apache.pdfbox.pdmodel.encryption.StandardProtectionPolicy;
import org.apache.pdfbox.pdmodel.font.PDType1Font;
import org.apache.pdfbox.pdmodel.font.Standard14Fonts;
import org.junit.jupiter.api.Test;

import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class PdfTextReaderTest {

    static byte[] pdf(List<List<String>> pages, String userPassword) throws IOException {
        try (PDDocument doc = new PDDocument(); ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            PDType1Font font = new PDType1Font(Standard14Fonts.FontName.HELVETICA);
            for (List<String> lines : pages) {
                PDPage page = new PDPage();
                doc.addPage(page);
                if (lines.isEmpty()) {
                    continue;
                }
                try (PDPageContentStream cs = new PDPageContentStream(doc, page)) {
                    cs.beginText();
                    cs.setFont(font, 11);
                    cs.newLineAtOffset(50, 720);
                    for (String line : lines) {
                        cs.showText(line);
                        cs.newLineAtOffset(0, -16);
                    }
                    cs.endText();
                }
            }
            if (userPassword != null) {
                StandardProtectionPolicy policy = new StandardProtectionPolicy("owner-secret", userPassword, new AccessPermission());
                policy.setEncryptionKeyLength(128);
                doc.protect(policy);
            }
            doc.save(out);
            return out.toByteArray();
        }
    }

    @Test
    void readsTextLinesPerPage() throws IOException {
        byte[] bytes = pdf(List.of(
                List.of("Proforma Invoice No. PI-2026-07", "Buyer: DELTA ELECTRICAL CO. LTD.", "KCL-01 curtain switch 5000 0.537"),
                List.of("Payment: T/T 30% deposit")), null);
        PdfTextReader.DocumentText text = PdfTextReader.read(bytes);
        assertThat(text.scanned()).isFalse();
        assertThat(text.pageCount()).isEqualTo(2);
        assertThat(text.pages().getFirst().lines()).contains("Proforma Invoice No. PI-2026-07", "KCL-01 curtain switch 5000 0.537");
        assertThat(text.allText()).contains("Payment: T/T 30% deposit");
        assertThat(DocumentSniffer.sniff(bytes, "file.pdf")).isEqualTo(DocumentKind.PDF);
    }

    @Test
    void pageWithoutTextIsTreatedAsScannedAndCanBeRendered() throws IOException {
        byte[] bytes = pdf(List.of(List.of()), null);
        PdfTextReader.DocumentText text = PdfTextReader.read(bytes);
        assertThat(text.scanned()).isTrue();
        List<byte[]> images = PdfTextReader.renderPages(bytes, 4);
        assertThat(images).hasSize(1);
        assertThat(images.getFirst()[0] & 0xFF).isEqualTo(0xFF);
        assertThat(images.getFirst()[1] & 0xFF).isEqualTo(0xD8);
    }

    @Test
    void passwordProtectedPdfIsRejectedWithPlainMessage() throws IOException {
        byte[] bytes = pdf(List.of(List.of("secret")), "open-me");
        assertThatThrownBy(() -> PdfTextReader.read(bytes)).isInstanceOf(ApiException.class).hasMessageContaining("密码");
    }

    @Test
    void brokenPdfIsRejected() {
        assertThatThrownBy(() -> PdfTextReader.read("%PDF-1.7 garbage".getBytes()))
                .isInstanceOf(ApiException.class).hasMessageContaining("PDF");
    }

    @Test
    void onlyTheFirstThirtyPagesAreRead() throws IOException {
        List<List<String>> pages = new java.util.ArrayList<>();
        for (int i = 0; i < PdfTextReader.MAX_PAGES + 3; i++) {
            pages.add(List.of("page " + (i + 1)));
        }
        PdfTextReader.DocumentText text = PdfTextReader.read(pdf(pages, null));
        assertThat(text.truncated()).isTrue();
        assertThat(text.pages()).hasSize(PdfTextReader.MAX_PAGES);
    }
    @Test
    void discardedLongLineMarksTheDocumentIncomplete() throws IOException {
        byte[] bytes;
        try (PDDocument doc = new PDDocument(); ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            PDPage page = new PDPage(new PDRectangle(10000, 100));
            doc.addPage(page);
            try (PDPageContentStream cs = new PDPageContentStream(doc, page)) {
                cs.beginText();
                cs.setFont(new PDType1Font(Standard14Fonts.FontName.HELVETICA), 1);
                cs.newLineAtOffset(1, 50);
                cs.showText("x".repeat(8193) + " Invoice No: second-invoice");
                cs.endText();
            }
            doc.save(out);
            bytes = out.toByteArray();
        }
        var result = PdfTextReader.read(bytes);
        assertThat(result.truncated()).isTrue();
        assertThat(result.pages().getFirst().lines().getFirst()).hasSize(8192);
    }

    /** 只有页面框、没有内容的 PDF(几百字节), 页面尺寸自定。 */
    static byte[] blankPage(PDRectangle box, float userUnit) throws IOException {
        try (PDDocument doc = new PDDocument(); ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            PDPage page = new PDPage(box);
            if (userUnit > 0) {
                page.setUserUnit(userUnit);
            }
            doc.addPage(page);
            doc.save(out);
            return out.toByteArray();
        }
    }

    @Test
    void hugePageIsRenderedWithinPixelBudget() throws IOException {
        // 14400 pt 见方(PDF 允许的最大页面, 约 5 米), 按 150 dpi 要 3 万 x 3 万像素、约 3.6 GB 位图。
        byte[] bytes = blankPage(new PDRectangle(14400, 14400), 0);
        assertThat(bytes.length).isLessThan(2048);
        List<byte[]> images = PdfTextReader.renderPages(bytes, 4);
        assertThat(images).hasSize(1);
        BufferedImage image = ImageIO.read(new ByteArrayInputStream(images.getFirst()));
        assertThat(Math.max(image.getWidth(), image.getHeight())).isLessThanOrEqualTo((int) PdfTextReader.MAX_RENDER_SIDE);
        assertThat((long) image.getWidth() * image.getHeight()).isLessThanOrEqualTo((long) PdfTextReader.MAX_RENDER_PIXELS);

        // 长条页面: 长边封顶。
        BufferedImage strip = ImageIO.read(new ByteArrayInputStream(
                PdfTextReader.renderPages(blankPage(new PDRectangle(14400, 200), 0), 1).getFirst()));
        assertThat(strip.getWidth()).isLessThanOrEqualTo((int) PdfTextReader.MAX_RENDER_SIDE);

        // 用户单位放大页面: 按放大后的尺寸算预算(只会更小)。
        byte[] scaled = blankPage(new PDRectangle(5000, 5000), 3f);
        BufferedImage small = ImageIO.read(new ByteArrayInputStream(PdfTextReader.renderPages(scaled, 1).getFirst()));
        assertThat((long) small.getWidth() * small.getHeight()).isLessThanOrEqualTo((long) PdfTextReader.MAX_RENDER_PIXELS);
    }

    @Test
    void normalPageKeeps150Dpi() throws IOException {
        byte[] bytes = blankPage(PDRectangle.A4, 0);
        BufferedImage image = ImageIO.read(new ByteArrayInputStream(PdfTextReader.renderPages(bytes, 1).getFirst()));
        assertThat(image.getWidth()).isBetween(1235, 1245);
        assertThat(image.getHeight()).isBetween(1748, 1758);
    }

    @Test
    void degeneratePageBoxIsRejectedAsUnreadable() throws IOException {
        byte[] bytes = blankPage(new PDRectangle(0, 0), 0);
        assertThatThrownBy(() -> PdfTextReader.renderPages(bytes, 1)).isInstanceOf(ApiException.class)
                .hasMessageContaining("打不开");
    }
}
