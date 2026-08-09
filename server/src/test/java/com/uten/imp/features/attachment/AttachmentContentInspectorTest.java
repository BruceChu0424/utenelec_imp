package com.uten.imp.features.attachment;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayInputStream;
import java.security.MessageDigest;
import java.util.Base64;
import java.util.HexFormat;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class AttachmentContentInspectorTest {

    private static final byte[] PNG = Base64.getDecoder().decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=");

    @Test
    void realPngProducesServerTrustedSha256() throws Exception {
        AttachmentContentInspector.Inspection result = AttachmentContentInspector.inspect(
                new ByteArrayInputStream(PNG), PNG.length, "receipt.png", "image/png");

        assertEquals(PNG.length, result.size());
        assertEquals(
                HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(PNG)),
                result.sha256());
    }

    @Test
    void textCannotMasqueradeAsPng() {
        byte[] fake = "not really an image".getBytes(java.nio.charset.StandardCharsets.UTF_8);

        ApiException failure = assertThrows(ApiException.class, () ->
                AttachmentContentInspector.inspect(
                        new ByteArrayInputStream(fake), fake.length, "receipt.png", "image/png"));

        assertEquals(ErrorCode.VALIDATION_FAILED, failure.getCode());
    }

    @Test
    void extensionMustAgreeWithDeclaredType() {
        ApiException failure = assertThrows(ApiException.class, () ->
                AttachmentContentInspector.inspect(
                        new ByteArrayInputStream(PNG), PNG.length, "receipt.txt", "image/png"));

        assertEquals(ErrorCode.VALIDATION_FAILED, failure.getCode());
    }
}
