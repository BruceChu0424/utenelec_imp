package com.uten.imp.common.files;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.nio.charset.StandardCharsets;

/** Checks raster dimensions from headers without allocating a decoded image. */
public final class ImageDimensionGuard {
    private static final long MAX_PIXELS = 40_000_000L;
    private static final int MAX_DIMENSION = 30_000;
    private ImageDimensionGuard() {}

    /**
     * Attachment inspection has a bounded prefix and supports non-raster formats, so it may
     * allow an unknown header. OCR supplies the complete PNG/JPEG/WebP and requires dimensions.
     */
    public static void requireSafe(byte[] bytes, int length, String type, boolean requireKnown) {
        int available = Math.min(length, bytes.length);
        Dimensions dimensions = switch (type) {
            case "image/png" -> available >= 24 && at(bytes, available, 12, "IHDR")
                    ? new Dimensions(u32be(bytes, 16), u32be(bytes, 20)) : null;
            case "image/gif" -> available >= 10
                    ? new Dimensions(u16le(bytes, 6), u16le(bytes, 8)) : null;
            case "image/bmp" -> available >= 26
                    ? new Dimensions(Math.abs(i32le(bytes, 18)), Math.abs(i32le(bytes, 22))) : null;
            case "image/jpeg" -> jpeg(bytes, available);
            case "image/webp" -> webp(bytes, available);
            default -> null;
        };
        if (dimensions == null) {
            if (requireKnown) throw invalid("无法确认图片尺寸，请选择完整的有效图片");
            return;
        }
        long width = dimensions.width(), height = dimensions.height();
        if (width <= 0 || height <= 0 || width > MAX_DIMENSION || height > MAX_DIMENSION
                || width * height > MAX_PIXELS) {
            throw invalid("图片尺寸超出允许范围(最大 4000 万像素，单边不超过 30000)，请压缩后重新上传");
        }
    }

    private static Dimensions jpeg(byte[] bytes, int length) {
        if (length < 4 || (bytes[0] & 255) != 255 || (bytes[1] & 255) != 216) return null;
        int position = 2;
        while (position + 3 < length) {
            if ((bytes[position] & 255) != 255) return null;
            int marker = bytes[position + 1] & 255;
            if (marker == 255 || marker == 1 || marker >= 208 && marker <= 217) {
                position += marker == 255 ? 1 : 2;
                continue;
            }
            if (marker == 218) return null; // Scan data before a frame header is invalid.
            int size = ((bytes[position + 2] & 255) << 8) | (bytes[position + 3] & 255);
            if (size < 2 || (long) position + 2 + size > length) return null;
            if (marker >= 192 && marker <= 207 && marker != 196 && marker != 200 && marker != 204) {
                if (size < 8) return null;
                int height = ((bytes[position + 5] & 255) << 8) | (bytes[position + 6] & 255);
                int width = ((bytes[position + 7] & 255) << 8) | (bytes[position + 8] & 255);
                return new Dimensions(width, height);
            }
            position += 2 + size;
        }
        return null;
    }

    private static Dimensions webp(byte[] bytes, int length) {
        if (at(bytes, length, 12, "VP8X") && length >= 30) {
            return new Dimensions(u24le(bytes, 24) + 1, u24le(bytes, 27) + 1);
        }
        if (at(bytes, length, 12, "VP8 ") && length >= 30
                && (bytes[23] & 255) == 157 && bytes[24] == 1 && bytes[25] == 42) {
            return new Dimensions(u16le(bytes, 26) & 0x3fff, u16le(bytes, 28) & 0x3fff);
        }
        if (at(bytes, length, 12, "VP8L") && length >= 25 && bytes[20] == 47) {
            long bits = i32le(bytes, 21);
            return new Dimensions((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1);
        }
        return null;
    }

    private static boolean at(byte[] bytes, int length, int offset, String expected) {
        return length >= offset + expected.length()
                && expected.equals(new String(bytes, offset, expected.length(), StandardCharsets.US_ASCII));
    }
    private static long u32be(byte[] bytes, int offset) {
        return ((long) (bytes[offset] & 255) << 24) | ((long) (bytes[offset + 1] & 255) << 16)
                | ((bytes[offset + 2] & 255) << 8) | (bytes[offset + 3] & 255);
    }
    private static long u24le(byte[] bytes, int offset) {
        return (bytes[offset] & 255) | ((bytes[offset + 1] & 255) << 8) | ((bytes[offset + 2] & 255) << 16);
    }
    private static long u16le(byte[] bytes, int offset) {
        return (bytes[offset] & 255) | ((bytes[offset + 1] & 255) << 8);
    }
    private static long i32le(byte[] bytes, int offset) {
        return (bytes[offset] & 255) | ((bytes[offset + 1] & 255) << 8)
                | ((bytes[offset + 2] & 255) << 16) | ((bytes[offset + 3] & 255) << 24);
    }
    private static ApiException invalid(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }
    private record Dimensions(long width, long height) {}
}
