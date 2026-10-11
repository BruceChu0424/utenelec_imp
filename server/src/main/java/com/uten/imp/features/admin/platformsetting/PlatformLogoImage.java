package com.uten.imp.features.admin.platformsetting;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import javax.imageio.ImageIO;
import javax.imageio.ImageReader;
import javax.imageio.stream.MemoryCacheImageInputStream;
import java.awt.Graphics2D;
import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Base64;
import java.util.HexFormat;
import java.util.Iterator;

/** Small raster-only brand asset; original bytes and metadata are discarded after decoding. */
final class PlatformLogoImage {
    static final int MAX_BYTES = 524288;
    static final int MAX_BASE64_CHARS = ((MAX_BYTES + 2) / 3) * 4;
    static final int MAX_DIMENSION = 2048;
    static final long MAX_PIXELS = 4194304L;
    private PlatformLogoImage() {}

    static byte[] decode(String encoded) {
        if (encoded == null || encoded.isEmpty() || encoded.length() > MAX_BASE64_CHARS)
            throw invalid("Logo 文件不能超过 512 KB");
        byte[] original;
        try { original = Base64.getDecoder().decode(encoded); }
        catch (IllegalArgumentException invalidBase64) { throw invalid("Logo 数据无效，请重新选择 PNG 或 JPEG 图片"); }
        if (original.length == 0 || original.length > MAX_BYTES) throw invalid("Logo 文件不能超过 512 KB");
        // Restrict the magic and the decoder; do not accept a script or arbitrary ImageIO plug-in format.
        boolean png = original.length >= 8 && original[0] == (byte) 0x89 && original[1] == 0x50
                && original[2] == 0x4e && original[3] == 0x47 && original[4] == 0x0d
                && original[5] == 0x0a && original[6] == 0x1a && original[7] == 0x0a;
        boolean jpeg = original.length >= 3 && original[0] == (byte) 0xff
                && original[1] == (byte) 0xd8 && original[2] == (byte) 0xff;
        if (!png && !jpeg) throw invalid("Logo 仅支持 PNG 或 JPEG 图片");
        Iterator<ImageReader> readers = ImageIO.getImageReadersByFormatName(png ? "PNG" : "JPEG");
        if (!readers.hasNext()) throw invalid("暂时无法处理 Logo 图片，请联系管理员");
        ImageReader reader = readers.next();
        try (var input = new MemoryCacheImageInputStream(new ByteArrayInputStream(original))) {
            reader.setInput(input, true, true);
            int width = reader.getWidth(0), height = reader.getHeight(0);
            if (width <= 0 || height <= 0 || width > MAX_DIMENSION || height > MAX_DIMENSION
                    || (long) width * height > MAX_PIXELS)
                throw invalid("Logo 单边不能超过 2048 像素，请缩小图片后重新上传");
            BufferedImage decoded = reader.read(0);
            if (decoded == null || decoded.getWidth() != width || decoded.getHeight() != height)
                throw invalid("Logo 图片内容不完整，请重新选择图片");
            BufferedImage clean = new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB);
            Graphics2D graphics = clean.createGraphics();
            try { graphics.drawImage(decoded, 0, 0, null); }
            finally { graphics.dispose(); decoded.flush(); }
            try {
                BoundedOutput output = new BoundedOutput();
                if (!ImageIO.write(clean, "PNG", output)) throw invalid("暂时无法处理 Logo 图片");
                return output.toByteArray();
            } finally { clean.flush(); }
        } catch (IOException | IllegalArgumentException error) {
            throw invalid("Logo 图片无效或转换后超过 512 KB，请压缩图片后重试");
        } finally { reader.dispose(); }
    }

    static String sha256(byte[] bytes) {
        try { return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes)); }
        catch (NoSuchAlgorithmException impossible) { throw new IllegalStateException(impossible); }
    }

    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }

    private static final class BoundedOutput extends ByteArrayOutputStream {
        @Override public synchronized void write(int value) {
            if (count >= MAX_BYTES) throw invalid("转换后的 Logo 超过 512 KB，请压缩图片后重试");
            super.write(value);
        }
        @Override public synchronized void write(byte[] bytes, int offset, int length) {
            if (length > MAX_BYTES - count) throw invalid("转换后的 Logo 超过 512 KB，请压缩图片后重试");
            super.write(bytes, offset, length);
        }
    }
}
