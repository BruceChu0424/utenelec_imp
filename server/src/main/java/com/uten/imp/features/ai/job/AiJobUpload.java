package com.uten.imp.features.ai.job;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.regex.Pattern;

/**
 * 上传内容的有界读取、文件名/类型清洗与文件类型嗅探(ADR-133)。
 *
 * <p>嗅探结果使用与 {@code common.files.document.DocumentKind} 相同的名称
 * (XLSX/XLS/CSV/PDF/PNG/JPEG/WEBP/UNSUPPORTED): 只看文件头魔数与扩展名, 不解压、不解析;
 * 深度校验(压缩炸弹、宏、加密等)由处理器用文档读取器完成。
 */
final class AiJobUpload {

    static final String UNSUPPORTED = "UNSUPPORTED";

    private static final Pattern CONTENT_TYPE = Pattern.compile("^[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+$");

    private AiJobUpload() {
    }

    /**
     * 有界读取: 声明长度超限直接拒绝, 读取中累计超限立即停止, 不会先整个读进内存再判断。
     */
    static byte[] readBounded(InputStream input, long declaredLength, long maxBytes) throws IOException {
        if (declaredLength > maxBytes) {
            throw tooLarge(maxBytes);
        }
        ByteArrayOutputStream output = new ByteArrayOutputStream(
                (int) Math.min(Math.max(declaredLength, 64 * 1024), Math.min(maxBytes, 4L * 1024 * 1024)));
        byte[] buffer = new byte[64 * 1024];
        long total = 0;
        int count;
        while ((count = input.read(buffer)) != -1) {
            if (count == 0) {
                continue;
            }
            if (total + count > maxBytes) {
                throw tooLarge(maxBytes);
            }
            output.write(buffer, 0, count);
            total += count;
        }
        if (total == 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "没有收到文件内容, 请重新选择文件");
        }
        return output.toByteArray();
    }

    private static ApiException tooLarge(long maxBytes) {
        long mib = Math.max(1, maxBytes / (1024 * 1024));
        return new ApiException(ErrorCode.PAYLOAD_TOO_LARGE, "文件超过 " + mib + " MB, 请压缩或拆分后再上传");
    }

    /** 请求头里的文件名(百分号编码的 UTF-8): 去掉路径与控制字符, 最长 255。 */
    static String fileName(String header) {
        String name = "";
        if (header != null && !header.isBlank()) {
            try {
                name = URLDecoder.decode(header.replace("+", "%2B"), StandardCharsets.UTF_8);
            } catch (IllegalArgumentException e) {
                name = "";
            }
        }
        int slash = Math.max(name.lastIndexOf('/'), name.lastIndexOf('\\'));
        if (slash >= 0) {
            name = name.substring(slash + 1);
        }
        StringBuilder cleaned = new StringBuilder(name.length());
        name.codePoints().filter(cp -> !Character.isISOControl(cp)).forEach(cleaned::appendCodePoint);
        String result = cleaned.toString().trim();
        if (result.isEmpty()) {
            return "upload";
        }
        return result.length() > 255 ? result.substring(result.length() - 255) : result;
    }

    /** 客户端声明的类型(只作参考)。不合规时记为 application/octet-stream。 */
    static String contentType(String header) {
        if (header == null) {
            return "application/octet-stream";
        }
        String value = header.trim();
        int semicolon = value.indexOf(';');
        if (semicolon >= 0) {
            value = value.substring(0, semicolon).trim();
        }
        return value.length() <= 128 && CONTENT_TYPE.matcher(value).matches()
                ? value.toLowerCase(Locale.ROOT) : "application/octet-stream";
    }

    /** 按文件头魔数(+ 扩展名)判断类型。 */
    static String sniff(byte[] bytes, String fileName) {
        String lower = fileName == null ? "" : fileName.toLowerCase(Locale.ROOT);
        if (startsWith(bytes, 0x25, 0x50, 0x44, 0x46, 0x2D)) {
            return "PDF";
        }
        if (startsWith(bytes, 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)) {
            return "PNG";
        }
        if (startsWith(bytes, 0xFF, 0xD8, 0xFF)) {
            return "JPEG";
        }
        if (bytes.length >= 12 && startsWith(bytes, 0x52, 0x49, 0x46, 0x46)
                && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) {
            return "WEBP";
        }
        if (startsWith(bytes, 0x50, 0x4B, 0x03, 0x04)) {
            return lower.endsWith(".xlsx") ? "XLSX" : UNSUPPORTED;
        }
        if (startsWith(bytes, 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)) {
            return lower.endsWith(".xls") ? "XLS" : UNSUPPORTED;
        }
        if ((lower.endsWith(".csv") || lower.endsWith(".txt")) && looksLikeText(bytes)) {
            return "CSV";
        }
        return UNSUPPORTED;
    }

    private static boolean looksLikeText(byte[] bytes) {
        int limit = Math.min(bytes.length, 8192);
        for (int i = 0; i < limit; i++) {
            if (bytes[i] == 0) {
                return false;
            }
        }
        return limit > 0;
    }

    private static boolean startsWith(byte[] bytes, int... magic) {
        if (bytes.length < magic.length) {
            return false;
        }
        for (int i = 0; i < magic.length; i++) {
            if ((bytes[i] & 0xff) != magic[i]) {
                return false;
            }
        }
        return true;
    }
}
