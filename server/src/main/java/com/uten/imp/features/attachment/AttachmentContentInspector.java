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

    /**
     * 头部缓存上限：需覆盖 JPEG SOF 段（EXIF 之后才出现）与各图片格式的尺寸字段，
     * 512 字节不够；64KB 对合法 JPEG（EXIF 缩略图通常 ≤20KB）足够宽松。
     */
    private static final int PREFIX_LIMIT = 64 * 1024;

    /** 图片像素总量上限（40MP）：A4@600dpi ≈ 8.5MP、8K 照片 ≈ 33MP 之外即为解压炸弹特征。 */
    private static final long MAX_PIXELS = 40L * 1000 * 1000;

    /** 单边像素上限：与主流解码器（libpng/Skia）的安全阈值一致。 */
    private static final int MAX_DIMENSION = 30000;

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
            boolean textOnly = "text/plain".equals(contentType);
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] prefix = new byte[PREFIX_LIMIT];
            int prefixLength = 0;
            long count = 0;
            boolean allText = true;
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
                // text/plain 需全量检测（二进制可能藏在 512 字节之后），反正流已全量读取。
                if (textOnly && allText) {
                    allText = isTextBytes(buffer, read);
                }
            }
            if (count != expectedSize) {
                throw invalid("附件对象在校验期间发生变化，请重新上传");
            }
            requireMagic(prefix, prefixLength, contentType, allText);
            requireSaneImageDimensions(prefix, prefixLength, contentType);
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

    private static void requireMagic(byte[] value, int length, String type, boolean allText) {
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
            case "text/plain" -> allText && length > 0;
            default -> false;
        };
        if (!valid) {
            throw invalid("文件实际内容与声明类型不一致");
        }
    }

    /**
     * 图片解压炸弹防护：客户端会全量解码图片（员工档案照片/证件扫描预览），
     * 一张 ≤25MB 的高压缩 PNG 可声明数万像素边长、解码后分配数 GB 内存。
     * 服务端在 confirm 阶段解析头部尺寸，超过像素/单边上限即拒绝。
     */
    private static void requireSaneImageDimensions(byte[] p, int length, String type) {
        long pixels = switch (type) {
            case "image/png" -> nonNegative(u32be(p, length, 16)) * nonNegative(u32be(p, length, 20));
            case "image/gif" -> nonNegative(u16le(p, length, 6)) * nonNegative(u16le(p, length, 8));
            case "image/bmp" -> Math.abs(i32le(p, length, 18)) * Math.abs(i32le(p, length, 22));
            case "image/jpeg" -> jpegPixels(p, length);
            case "image/webp" -> webpPixels(p, length);
            default -> -1L;
        };
        if (pixels < 0) {
            return;
        }
        if (pixels == 0 || pixels > MAX_PIXELS) {
            throw invalid("图片尺寸超出允许范围（最大 4000 万像素），请压缩后重新上传");
        }
    }

    /** 解析失败（-1）统一归零路径，避免 -1 × -1 = 1 之类的绕过。 */
    private static long nonNegative(long value) {
        return value < 0 ? 0L : value;
    }

    /** JPEG：跳过 EXIF 等段找 SOFn（C0-CF，除 C4/C8/CC），段内为 高度|宽度 各 2 字节大端。 */
    private static long jpegPixels(byte[] p, int length) {
        if (length < 4 || (p[0] & 0xff) != 0xff || (p[1] & 0xff) != 0xd8) {
            return -1L;
        }
        int i = 2;
        while (i + 9 < length) {
            if ((p[i] & 0xff) != 0xff) {
                i++;
                continue;
            }
            int marker = p[i + 1] & 0xff;
            if (marker == 0xff || marker == 0x01 || (marker >= 0xd0 && marker <= 0xd9)) {
                i += 2;
                continue;
            }
            int segmentLength = ((p[i + 2] & 0xff) << 8) | (p[i + 3] & 0xff);
            if (segmentLength < 2) {
                return -1L;
            }
            if (marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc) {
                int height = ((p[i + 5] & 0xff) << 8) | (p[i + 6] & 0xff);
                int width = ((p[i + 7] & 0xff) << 8) | (p[i + 8] & 0xff);
                if (width > MAX_DIMENSION || height > MAX_DIMENSION) {
                    return Long.MAX_VALUE;
                }
                return (long) width * height;
            }
            i += 2 + segmentLength;
        }
        return -1L;
    }

    /** WebP：VP8X 画布 24 位小端（24/27 偏移）；VP8 关键帧与 VP8L 的 14 位打包尺寸。 */
    private static long webpPixels(byte[] p, int length) {
        if (atAscii(p, length, 12, "VP8X")) {
            if (length < 30) {
                return -1L;
            }
            long w = (p[24] & 0xff) | ((p[25] & 0xff) << 8) | ((p[26] & 0xff) << 16);
            long h = (p[27] & 0xff) | ((p[28] & 0xff) << 8) | ((p[29] & 0xff) << 16);
            return (w + 1) * (h + 1);
        }
        if (atAscii(p, length, 12, "VP8 ")) {
            if (length < 30) {
                return -1L;
            }
            int w = ((p[26] & 0xff) | ((p[27] & 0xff) << 8)) & 0x3fff;
            int h = ((p[28] & 0xff) | ((p[29] & 0xff) << 8)) & 0x3fff;
            return (long) w * h;
        }
        if (atAscii(p, length, 12, "VP8L")) {
            if (length < 26) {
                return -1L;
            }
            int bits = (p[21] & 0xff) | ((p[22] & 0xff) << 8) | ((p[23] & 0xff) << 16) | ((p[24] & 0xff) << 24);
            int w = (bits & 0x3fff) + 1;
            int h = ((bits >> 14) & 0x3fff) + 1;
            return (long) w * h;
        }
        return -1L;
    }

    private static long u32be(byte[] p, int length, int offset) {
        if (length < offset + 4 || (p[offset] & 0x80) != 0) {
            return -1L;
        }
        return ((long) (p[offset] & 0xff) << 24) | ((p[offset + 1] & 0xff) << 16)
                | ((p[offset + 2] & 0xff) << 8) | (p[offset + 3] & 0xff);
    }

    private static long u16le(byte[] p, int length, int offset) {
        if (length < offset + 2) {
            return -1L;
        }
        return (p[offset] & 0xff) | ((p[offset + 1] & 0xff) << 8);
    }

    private static long i32le(byte[] p, int length, int offset) {
        if (length < offset + 4) {
            return -1L;
        }
        return (p[offset] & 0xff) | ((p[offset + 1] & 0xff) << 8)
                | ((p[offset + 2] & 0xff) << 16) | ((p[offset + 3] & 0xff) << 24);
    }

    private static boolean isZip(byte[] value, int length) {
        return starts(value, length, 0x50, 0x4b, 0x03, 0x04)
                || starts(value, length, 0x50, 0x4b, 0x05, 0x06)
                || starts(value, length, 0x50, 0x4b, 0x07, 0x08);
    }

    private static boolean isTextBytes(byte[] value, int length) {
        for (int index = 0; index < length; index++) {
            int current = value[index] & 0xff;
            if (current == 0 || current < 0x09 || current > 0x0d && current < 0x20) {
                return false;
            }
        }
        return true;
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
