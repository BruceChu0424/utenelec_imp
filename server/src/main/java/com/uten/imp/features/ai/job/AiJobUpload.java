package com.uten.imp.features.ai.job;

import com.uten.imp.common.files.document.BoundedBodyReader;
import com.uten.imp.common.files.document.DocumentKind;
import com.uten.imp.common.files.document.DocumentSniffer;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.io.IOException;
import java.io.InputStream;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.regex.Pattern;

/**
 * 上传内容的有界读取、文件名/类型清洗与文件类型嗅探(ADR-133)。
 *
 * <p>有界读取与嗅探直接用公共文档读取层({@link BoundedBodyReader}、{@link DocumentSniffer}), 与处理器解析时
 * 同一口径, 嗅探结果就是 {@link DocumentKind} 的名称(XLSX/XLS/CSV/PDF/PNG/JPEG/WEBP/UNSUPPORTED):
 * 只看文件头魔数与扩展名, 不解析; 深度校验(压缩炸弹、宏、加密等)由处理器用文档读取器完成。
 */
final class AiJobUpload {

    static final String UNSUPPORTED = DocumentKind.UNSUPPORTED.name();

    private static final Pattern CONTENT_TYPE = Pattern.compile("^[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+$");

    private AiJobUpload() {
    }

    /**
     * 有界读取: 声明长度超限直接拒绝, 读取中累计超限立即停止, 不会先整个读进内存再判断; 没有内容 422。
     */
    static byte[] readBounded(InputStream input, long declaredLength, long maxBytes) throws IOException {
        byte[] bytes = BoundedBodyReader.read(input, declaredLength, maxBytes);
        if (bytes.length == 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "没有收到文件内容, 请重新选择文件");
        }
        return bytes;
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

    /** 按文件头魔数(+ 扩展名)判断类型, 返回 DocumentKind 名称。 */
    static String sniff(byte[] bytes, String fileName) {
        return DocumentSniffer.sniff(bytes, fileName).name();
    }
}
