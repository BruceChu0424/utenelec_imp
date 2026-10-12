package com.uten.imp.features.admin.platformsetting;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.util.Base64;
import java.util.Random;
import static org.junit.jupiter.api.Assertions.*;

class PlatformLogoImageTest {
    @Test void validPngRetainsTransparentPixelsAndProducesOnlyPng() throws Exception {
        var original = new BufferedImage(12, 8, BufferedImage.TYPE_INT_ARGB);
        original.setRGB(2, 3, 0x7f123456);
        byte[] clean = PlatformLogoImage.decode(encoded(original, "PNG"));
        var result = ImageIO.read(new ByteArrayInputStream(clean));
        assertEquals(12, result.getWidth()); assertEquals(8, result.getHeight());
        assertEquals(original.getRGB(2, 3), result.getRGB(2, 3));
        assertEquals(64, PlatformLogoImage.sha256(clean).length());
    }

    @Test void jpegIsReencodedToPngAndTrailingInputIsDiscarded() throws Exception {
        var source = new BufferedImage(10, 10, BufferedImage.TYPE_INT_RGB);
        byte[] jpeg = Base64.getDecoder().decode(encoded(source, "JPEG"));
        byte[] dirty = java.util.Arrays.copyOf(jpeg, jpeg.length + 20);
        System.arraycopy("private-metadata".getBytes(), 0, dirty, jpeg.length, 16);
        byte[] clean = PlatformLogoImage.decode(Base64.getEncoder().encodeToString(dirty));
        assertEquals((byte) 0x89, clean[0]);
        assertFalse(new String(clean, java.nio.charset.StandardCharsets.ISO_8859_1).contains("private-metadata"));
    }

    @Test void unsupportedScriptsGifTruncatedAndInvalidBase64AreRejected() {
        for (String value : new String[]{"", "not-base64", "data:image/png;base64,aaa", "<svg/>",
                Base64.getEncoder().encodeToString("GIF89a".getBytes()),
                Base64.getEncoder().encodeToString(new byte[]{(byte) 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a})})
            assertThrows(ApiException.class, () -> PlatformLogoImage.decode(value));
    }

    @Test void oversizedInputIsRejectedBeforeDecoding() {
        assertThrows(ApiException.class, () -> PlatformLogoImage.decode(
                Base64.getEncoder().encodeToString(new byte[PlatformLogoImage.MAX_BYTES + 1])));
    }

    @Test void dimensionsAreCheckedBeforeRasterAllocation() throws Exception {
        String encoded = encoded(new BufferedImage(2049, 1, BufferedImage.TYPE_INT_ARGB), "PNG");
        assertThrows(ApiException.class, () -> PlatformLogoImage.decode(encoded));
    }

    @Test void compressedJpegThatExpandsPastOutputLimitIsRejected() throws Exception {
        var source = new BufferedImage(700, 700, BufferedImage.TYPE_INT_RGB);
        Random random = new Random(12);
        for (int y = 0; y < 700; y++) for (int x = 0; x < 700; x++) source.setRGB(x, y, random.nextInt(0x1000000));
        String encoded = encoded(source, "JPEG");
        assertTrue(Base64.getDecoder().decode(encoded).length < PlatformLogoImage.MAX_BYTES);
        assertThrows(ApiException.class, () -> PlatformLogoImage.decode(encoded));
    }

    static String encoded(BufferedImage image, String format) throws Exception {
        var output = new ByteArrayOutputStream();
        assertTrue(ImageIO.write(image, format, output));
        return Base64.getEncoder().encodeToString(output.toByteArray());
    }
}
