package com.uten.imp.common.web;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.text.Normalizer;

/**
 * 兼容中文文件名的下载响应头。
 *
 * <p>同时提供 ASCII {@code filename} 回退和 RFC 5987 UTF-8 {@code filename*}，
 * 并剔除路径、控制字符与 CR/LF，避免响应头注入。
 */
public final class DownloadContentDisposition {

    private static final int MAX_FILENAME_CODE_POINTS = 180;

    private DownloadContentDisposition() {}

    public static String attachment(String requestedFilename) {
        String safeUnicode = sanitize(requestedFilename);
        String asciiFallback = asciiFallback(safeUnicode);
        String encoded = URLEncoder.encode(safeUnicode, StandardCharsets.UTF_8)
                .replace("+", "%20");
        return "attachment; filename=\"" + asciiFallback
                + "\"; filename*=UTF-8''" + encoded;
    }

    private static String sanitize(String requestedFilename) {
        String value = requestedFilename == null
                ? ""
                : Normalizer.normalize(requestedFilename, Normalizer.Form.NFC).strip();
        value = value.replace('\\', '_').replace('/', '_');
        StringBuilder safe = new StringBuilder();
        value.codePoints()
                .filter(cp -> !Character.isISOControl(cp))
                .limit(MAX_FILENAME_CODE_POINTS)
                .forEach(safe::appendCodePoint);
        String result = safe.toString().strip();
        return result.isEmpty() || ".".equals(result) || "..".equals(result)
                ? "download"
                : result;
    }

    private static String asciiFallback(String safeUnicode) {
        int dot = safeUnicode.lastIndexOf('.');
        String extension = "";
        String stem = safeUnicode;
        if (dot > 0 && dot < safeUnicode.length() - 1) {
            String candidate = safeUnicode.substring(dot + 1);
            if (candidate.matches("[A-Za-z0-9]{1,10}")) {
                extension = "." + candidate;
                stem = safeUnicode.substring(0, dot);
            }
        }
        String asciiStem = stem.replaceAll("[^A-Za-z0-9._-]+", "_")
                .replaceAll("^[_\\.]+|[_\\.]+$", "");
        if (asciiStem.isEmpty() || !asciiStem.matches(".*[A-Za-z0-9].*")) {
            asciiStem = "download";
        }
        return asciiStem + extension;
    }
}
