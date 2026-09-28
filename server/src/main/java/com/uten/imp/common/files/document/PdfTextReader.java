package com.uten.imp.common.files.document;

import com.uten.imp.common.files.document.DocumentParseGate.Deadline;
import com.uten.imp.common.web.ApiException;
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.io.MemoryUsageSetting;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PDPage;
import org.apache.pdfbox.pdmodel.common.PDRectangle;
import org.apache.pdfbox.pdmodel.encryption.InvalidPasswordException;
import org.apache.pdfbox.rendering.ImageType;
import org.apache.pdfbox.rendering.PDFRenderer;
import org.apache.pdfbox.text.PDFTextStripper;

import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

/**
 * PDF 文字层读取(PDFBox 3): 只取文字, 不执行脚本、不打开附件、不联网。
 *
 * <p>上限: 最多 30 页; 解析缓存 32 MiB 内存 + 256 MiB 临时文件; 墙钟 60 秒(与表格共用闸门)。
 * 全部文字少于 20 个非空白字符视为扫描件({@link DocumentText#scanned()}), 这时只能交给支持图片的模型,
 * 可用 {@link #renderPages} 把前几页渲染成 JPEG(每页有像素上限, 见 {@link #renderScale})。
 */
public final class PdfTextReader {

    public static final int MAX_PAGES = 30;
    static final int SCANNED_THRESHOLD_CHARS = 20;
    private static final long MAIN_MEMORY_BYTES = 32L * 1024 * 1024;
    private static final long STORAGE_BYTES = 256L * 1024 * 1024;
    /** 渲染给图片模型的分辨率(每英寸点数): A4 约 1240x1754, 足够看清表格文字。 */
    private static final float RENDER_DPI = 150f;
    /** 渲染一页最多多少像素(约 1200 万, RGB 位图约 48 MB)。A4 按 150 dpi 约 220 万像素。 */
    static final double MAX_RENDER_PIXELS = 12_000_000d;
    /** 渲染图片长边最多多少像素。 */
    static final double MAX_RENDER_SIDE = 4000d;
    private static final String UNREADABLE = "这个 PDF 文件打不开或已损坏, 请重新导出后再试";

    private PdfTextReader() {
    }

    /** 读取文字; 打不开/有密码抛 422。 */
    public static DocumentText read(byte[] bytes) {
        return DocumentParseGate.run(deadline -> read(bytes, deadline));
    }

    static DocumentText read(byte[] bytes, Deadline deadline) {
        try (PDDocument doc = load(bytes)) {
            int pageCount = doc.getNumberOfPages();
            int limit = Math.min(pageCount, MAX_PAGES);
            PDFTextStripper stripper = new PDFTextStripper();
            stripper.setSortByPosition(true);
            stripper.setLineSeparator("\n");
            List<DocumentText.Page> pages = new ArrayList<>(limit);
            int visibleChars = 0;
            for (int p = 1; p <= limit; p++) {
                deadline.check();
                stripper.setStartPage(p);
                stripper.setEndPage(p);
                String text = stripper.getText(doc);
                List<String> lines = new ArrayList<>();
                for (String raw : text.split("\n")) {
                    String line = raw.replace('\u00A0', ' ').strip();
                    if (line.isEmpty()) {
                        continue;
                    }
                    if (line.length() > SpreadsheetGridReader.MAX_CELL_CHARS) {
                        line = line.substring(0, SpreadsheetGridReader.MAX_CELL_CHARS);
                    }
                    lines.add(line);
                    visibleChars += line.replaceAll("\\s+", "").length();
                }
                pages.add(new DocumentText.Page(p, lines));
            }
            return new DocumentText(pages, visibleChars < SCANNED_THRESHOLD_CHARS, pageCount > limit, pageCount);
        } catch (ApiException e) {
            throw e;
        } catch (InvalidPasswordException e) {
            throw ZipSafety.rejected("这个 PDF 设置了打开密码, 请去掉密码后再上传");
        } catch (IOException | RuntimeException e) {
            throw ZipSafety.rejected(UNREADABLE);
        }
    }

    /**
     * 把前 {@code maxPages} 页渲染成 JPEG(扫描件交给图片模型用)。
     */
    public static List<byte[]> renderPages(byte[] bytes, int maxPages) {
        return DocumentParseGate.run(deadline -> renderPages(bytes, maxPages, deadline));
    }

    static List<byte[]> renderPages(byte[] bytes, int maxPages, Deadline deadline) {
        try (PDDocument doc = load(bytes)) {
            PDFRenderer renderer = new PDFRenderer(doc);
            int limit = Math.min(doc.getNumberOfPages(), Math.max(0, maxPages));
            List<byte[]> images = new ArrayList<>(limit);
            for (int p = 0; p < limit; p++) {
                deadline.check();
                float scale = renderScale(doc.getPage(p));
                BufferedImage image = renderer.renderImage(p, scale, ImageType.RGB);
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                if (!ImageIO.write(image, "jpg", out)) {
                    throw new IOException("no jpeg writer");
                }
                images.add(out.toByteArray());
            }
            return images;
        } catch (ApiException e) {
            throw e;
        } catch (InvalidPasswordException e) {
            throw ZipSafety.rejected("这个 PDF 设置了打开密码, 请去掉密码后再上传");
        } catch (IOException | RuntimeException e) {
            throw ZipSafety.rejected(UNREADABLE);
        }
    }

    /**
     * 渲染倍率(每个 PDF 点对应的像素): 平常按 150 dpi; 页面很大时缩小, 保证一页不超过 {@link #MAX_RENDER_PIXELS} 像素、
     * 长边不超过 {@link #MAX_RENDER_SIDE} 像素 —— 几百字节的 PDF 可以声明一张几十米见方的页面, 按 150 dpi 渲染会一次
     * 申请几 GB 内存。页面尺寸按裁剪框乘「用户单位」计(PDFBox 目前渲染时不乘用户单位, 这里按大的算, 只会更保守)。
     * 裁剪框不是有限正数时按文件损坏处理。
     */
    static float renderScale(PDPage page) {
        PDRectangle box = page.getCropBox();
        float unit = page.getUserUnit();
        double userUnit = Float.isFinite(unit) && unit > 1 ? unit : 1;
        double width = box == null ? Double.NaN : box.getWidth() * userUnit;
        double height = box == null ? Double.NaN : box.getHeight() * userUnit;
        if (!Double.isFinite(width) || !Double.isFinite(height) || width <= 0 || height <= 0) {
            throw ZipSafety.rejected(UNREADABLE);
        }
        double scale = RENDER_DPI / 72.0;
        scale = Math.min(scale, Math.sqrt(MAX_RENDER_PIXELS / (width * height)));
        scale = Math.min(scale, MAX_RENDER_SIDE / Math.max(width, height));
        return (float) scale;
    }

    private static PDDocument load(byte[] bytes) throws IOException {
        MemoryUsageSetting memory = MemoryUsageSetting.setupMixed(MAIN_MEMORY_BYTES, STORAGE_BYTES);
        return Loader.loadPDF(bytes, "", null, null, memory.streamCache);
    }

    /**
     * PDF 文字。
     *
     * @param pages      已读的页(最多 30 页)
     * @param scanned    几乎没有文字(扫描件/图片型 PDF)
     * @param truncated  页数超过上限, 后面的页没有读
     * @param pageCount  PDF 总页数
     */
    public record DocumentText(List<Page> pages, boolean scanned, boolean truncated, int pageCount) {

        public DocumentText {
            pages = List.copyOf(Objects.requireNonNull(pages, "pages"));
        }

        /** 某页的文字行。 */
        public record Page(int number, List<String> lines) {
            public Page {
                lines = List.copyOf(lines);
            }
        }

        /** 全部文字(页之间空一行)。 */
        public String allText() {
            StringBuilder sb = new StringBuilder();
            for (Page page : pages) {
                if (!sb.isEmpty()) {
                    sb.append("\n\n");
                }
                sb.append(String.join("\n", page.lines()));
            }
            return sb.toString();
        }
    }
}
