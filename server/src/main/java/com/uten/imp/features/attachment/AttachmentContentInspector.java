package com.uten.imp.features.attachment;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.io.IOException;
import java.io.InputStream;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/** Computes a server-trusted SHA-256 and rejects obvious extension/magic-byte mismatches. */
final class AttachmentContentInspector {

    private static final int PREFIX_LIMIT = 512;
    private static final Map<String, Set<String>> EXTENSIONS = Map.ofEntries(
            Map.entry("image/jpeg", Set.of("jpg", "jpeg")),
            Map.entry("image/png", Set.of("png")),
            Map.entry("image/webp", Set.of("webp")),
            Map.entry("image/gif", Set.of("gif")),
            Map.entry("image/bmp", Set.of("bmp")),
            Map.entry("application/pdf", Set.of("pdf")),
            Map.entry("application/msword", Set.of("doc")),
            Map.entry("application/vnd.ms-excel", Set.of("xls")),
            Map.entry("application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                    Set.of("docx")),
            Map.entry("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    Set.of("xlsx")),
            Map.entry("application/zip", Set.of("zip")),
            Map.entry("text/plain", Set.of("txt")));

    private AttachmentContentInspector() {
    }

    static Inspection inspect(InputStream input, long expectedSize,
                              String fileName, String contentType) {
        try (InputStream in = input) {
            requireExtension(fileName, contentType);
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] prefix = new byte[PREFIX_LIMIT];
            int prefixLength = 0;
            long count = 0;
            byte[] buffer = new byte[8192];
            int read;
            while ((read = in.read(buffer)) != -1) {
                if (prefixLength < prefix.length) {
                    int copy = Math.min(read, prefix.length - prefixLength);
                    System.arraycopy(buffer, 0, prefix, prefixLength, copy);
                    prefixLength += copy;
                }
                digest.update(buffer, 0, read);
                count += read;
                if (count > expectedSize) {
                    throw invalid("附件对象在校验期间发生变化，请重新上传");
                }
            }
            if (count != expectedSize) {
                throw invalid("附件对象在校验期间发生变化，请重新上传");
            }
            requireMagic(prefix, prefixLength, contentType);
            return new Inspection(HexFormat.of().formatHex(digest.digest()), count);
        } catch (ApiException e) {
            throw e;
        } catch (IOException e) {
            throw new ApiException(ErrorCode.CONFLICT, "无法读取已上传附件，请重新上传");
        } catch (Exception e) {
            throw new IllegalStateException("无法计算附件 SHA-256", e);
        }
    }

    private static void requireExtension(String fileName, String contentType) {
        Set<String> allowed = EXTENSIONS.get(contentType);
        int dot = fileName.lastIndexOf('.');
        String extension = dot < 0 || dot == fileName.length() - 1
                ? "" : fileName.substring(dot + 1).toLowerCase(Locale.ROOT);
        if (allowed == null || !allowed.contains(extension)) {
            throw invalid("文件扩展名与声明类型不一致");
        }
    }

    private static void requireMagic(byte[] value, int length, String type) {
        boolean valid = switch (type) {
            case "image/jpeg" -> starts(value, length, 0xff, 0xd8, 0xff);
            case "image/png" -> starts(value, length, 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a);
            case "image/webp" -> startsAscii(value, length, "RIFF")
                    && atAscii(value, length, 8, "WEBP");
            case "image/gif" -> startsAscii(value, length, "GIF87a")
                    || startsAscii(value, length, "GIF89a");
            case "image/bmp" -> startsAscii(value, length, "BM");
            case "application/pdf" -> startsAscii(value, length, "%PDF-");
            case "application/msword", "application/vnd.ms-excel" ->
                    starts(value, length, 0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1);
            case "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                 "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                 "application/zip" -> isZip(value, length);
            case "text/plain" -> looksLikeText(value, length);
            default -> false;
        };
        if (!valid) {
            throw invalid("文件实际内容与声明类型不一致");
        }
    }

    private static boolean isZip(byte[] value, int length) {
        return starts(value, length, 0x50, 0x4b, 0x03, 0x04)
                || starts(value, length, 0x50, 0x4b, 0x05, 0x06)
                || starts(value, length, 0x50, 0x4b, 0x07, 0x08);
    }

    private static boolean looksLikeText(byte[] value, int length) {
        for (int index = 0; index < length; index++) {
            int current = value[index] & 0xff;
            if (current == 0 || current < 0x09 || current > 0x0d && current < 0x20) {
                return false;
            }
        }
        return length > 0;
    }

    private static boolean startsAscii(byte[] value, int length, String expected) {
        return atAscii(value, length, 0, expected);
    }

    private static boolean atAscii(byte[] value, int length, int offset, String expected) {
        if (length < offset + expected.length()) {
            return false;
        }
        for (int index = 0; index < expected.length(); index++) {
            if ((value[offset + index] & 0xff) != expected.charAt(index)) {
                return false;
            }
        }
        return true;
    }

    private static boolean starts(byte[] value, int length, int... expected) {
        if (length < expected.length) {
            return false;
        }
        for (int index = 0; index < expected.length; index++) {
            if ((value[index] & 0xff) != expected[index]) {
                return false;
            }
        }
        return true;
    }

    private static ApiException invalid(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    record Inspection(String sha256, long size) {
    }
}
