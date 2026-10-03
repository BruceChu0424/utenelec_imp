package com.uten.imp.common.files.document;

import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.Charset;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.Locale;

/**
 * 按文件头(魔数)判断上传文件的真实类型。
 *
 * <ul>
 *   <li>PDF / PNG / JPEG / WEBP 只看魔数;</li>
 *   <li>ZIP 魔数 + (扩展名 .xlsx 或压缩包目录里出现 {@code xl/} 部件) → XLSX; 带宏的 .xlsm/.xltm 不收;</li>
 *   <li>OLE2 魔数 + 扩展名 .xls(或加密后的 .xlsx) → XLS(真正是否工作簿由读取器确认);</li>
 *   <li>扩展名 .csv 且内容是可解码的文本(UTF-8 或 GB18030, 无 NUL 字节) → CSV。</li>
 * </ul>
 */
public final class DocumentSniffer {

    private static final byte[] PDF = "%PDF-".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] PNG = {(byte) 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
    private static final byte[] ZIP = {'P', 'K', 0x03, 0x04};
    private static final byte[] OLE2 = {(byte) 0xD0, (byte) 0xCF, 0x11, (byte) 0xE0, (byte) 0xA1, (byte) 0xB1, 0x1A,
            (byte) 0xE1};
    /** PDF 规范允许魔数前有少量垃圾字节; 只在开头 1 KiB 内找。 */
    private static final int PDF_SEARCH_WINDOW = 1024;
    private static final int TEXT_PROBE_BYTES = 64 * 1024;

    private DocumentSniffer() {
    }

    /**
     * @param head     文件开头若干字节(传整个文件也可以; ZIP 判断会在其中搜索部件名)
     * @param fileName 原始文件名(只用于区分 CSV 与 XLS/XLSX 的扩展名), 可为空
     */
    public static DocumentKind sniff(byte[] head, String fileName) {
        if (head == null || head.length == 0) {
            return DocumentKind.UNSUPPORTED;
        }
        String ext = extension(fileName);
        if (startsWith(head, PNG)) {
            return DocumentKind.PNG;
        }
        if (head.length >= 3 && (head[0] & 0xFF) == 0xFF && (head[1] & 0xFF) == 0xD8 && (head[2] & 0xFF) == 0xFF) {
            return DocumentKind.JPEG;
        }
        if (head.length >= 12 && head[0] == 'R' && head[1] == 'I' && head[2] == 'F' && head[3] == 'F'
                && head[8] == 'W' && head[9] == 'E' && head[10] == 'B' && head[11] == 'P') {
            return DocumentKind.WEBP;
        }
        if (indexOf(head, PDF, Math.min(head.length, PDF_SEARCH_WINDOW)) >= 0) {
            return DocumentKind.PDF;
        }
        if (startsWith(head, ZIP)) {
            if (ext.equals("xlsm") || ext.equals("xltm") || ext.equals("xlam") || ext.equals("docm") || ext.equals("dotm")) {
                return DocumentKind.UNSUPPORTED;
            }
            if (ext.equals("xlsx") || ext.equals("xltx")
                    || indexOf(head, "xl/".getBytes(StandardCharsets.US_ASCII), head.length) >= 0) {
                return DocumentKind.XLSX;
            }
            if (ext.equals("docx") && indexOf(head, "word/document.xml".getBytes(StandardCharsets.US_ASCII), head.length) >= 0)
                return DocumentKind.DOCX;
            return DocumentKind.UNSUPPORTED;
        }
        if (startsWith(head, OLE2)) {
            // 加了打开密码的 .xlsx 实际是 OLE2 容器: 也交给 XLS 读取器, 由它给出「请去掉密码」的提示。
            return ext.equals("xls") || ext.equals("xlt") || ext.equals("xlsx") ? DocumentKind.XLS
                    : DocumentKind.UNSUPPORTED;
        }
        if ((ext.equals("csv") || ext.equals("txt")) && isDecodableText(head)) {
            return DocumentKind.CSV;
        }
        return DocumentKind.UNSUPPORTED;
    }

    /** 小写扩展名(不含点); 没有返回空串。 */
    static String extension(String fileName) {
        if (fileName == null) {
            return "";
        }
        String name = fileName.strip();
        int slash = Math.max(name.lastIndexOf('/'), name.lastIndexOf('\\'));
        if (slash >= 0) {
            name = name.substring(slash + 1);
        }
        int dot = name.lastIndexOf('.');
        return dot < 0 || dot == name.length() - 1 ? "" : name.substring(dot + 1).toLowerCase(Locale.ROOT);
    }

    private static boolean isDecodableText(byte[] head) {
        int length = Math.min(head.length, TEXT_PROBE_BYTES);
        for (int i = 0; i < length; i++) {
            if (head[i] == 0) {
                return false;
            }
        }
        // 截断处可能切断一个多字节字符: 去掉末尾最多 3 个字节再判断。
        int trimmed = head.length > TEXT_PROBE_BYTES ? Math.max(0, length - 3) : length;
        return decodes(head, trimmed, StandardCharsets.UTF_8) || decodes(head, trimmed, Charset.forName("GB18030"));
    }

    static boolean decodes(byte[] bytes, int length, Charset charset) {
        try {
            charset.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes, 0, length));
            return true;
        } catch (CharacterCodingException e) {
            return false;
        }
    }

    private static boolean startsWith(byte[] data, byte[] prefix) {
        if (data.length < prefix.length) {
            return false;
        }
        for (int i = 0; i < prefix.length; i++) {
            if (data[i] != prefix[i]) {
                return false;
            }
        }
        return true;
    }

    private static int indexOf(byte[] data, byte[] needle, int limit) {
        int end = Math.min(limit, data.length) - needle.length;
        outer:
        for (int i = 0; i <= end; i++) {
            for (int j = 0; j < needle.length; j++) {
                if (data[i + j] != needle[j]) {
                    continue outer;
                }
            }
            return i;
        }
        return -1;
    }
}
