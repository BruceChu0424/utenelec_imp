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

    @Test
    void pngDecompressionBombIsRejected() {
        // 合法 PNG 魔数 + IHDR 声明 40000×40000（16 亿像素 > 40MP 上限）
        byte[] bomb = new byte[64];
        System.arraycopy(PNG, 0, bomb, 0, 16); // 签名 + IHDR 长度/类型 + width 字段起点
        bomb[16] = 0x00; bomb[17] = 0x00; bomb[18] = (byte) 0x9c; bomb[19] = 0x40; // 40000
        bomb[20] = 0x00; bomb[21] = 0x00; bomb[22] = (byte) 0x9c; bomb[23] = 0x40; // 40000

        ApiException failure = assertThrows(ApiException.class, () ->
                AttachmentContentInspector.inspect(
                        new ByteArrayInputStream(bomb), bomb.length, "scan.png", "image/png"));

        assertEquals(ErrorCode.VALIDATION_FAILED, failure.getCode());
    }

    @Test
    void gifDecompressionBombIsRejected() {
        // GIF89a + 逻辑屏幕 65535×65535（约 43 亿像素）
        byte[] bomb = new byte[] {
                'G', 'I', 'F', '8', '9', 'a',
                (byte) 0xff, (byte) 0xff, (byte) 0xff, (byte) 0xff
        };

        ApiException failure = assertThrows(ApiException.class, () ->
                AttachmentContentInspector.inspect(
                        new ByteArrayInputStream(bomb), bomb.length, "anim.gif", "image/gif"));

        assertEquals(ErrorCode.VALIDATION_FAILED, failure.getCode());
    }

    @Test
    void textWithBinaryBeyondPrefixIsRejected() {
        // 前 1KB 全是可打印文本，其后藏一个 NUL——旧实现只查前 512 字节会放行
        byte[] malicious = new byte[2048];
        java.util.Arrays.fill(malicious, 0, 1024, (byte) 'a');
        malicious[1500] = 0x00;

        ApiException failure = assertThrows(ApiException.class, () ->
                AttachmentContentInspector.inspect(
                        new ByteArrayInputStream(malicious), malicious.length, "note.txt", "text/plain"));

        assertEquals(ErrorCode.VALIDATION_FAILED, failure.getCode());
    }

    @Test
    void plainTextStillPasses() {
        byte[] text = "工资变量说明\n1. 加班费按 1.5 倍计算\r\n2. 奖金次月发放".getBytes(
                java.nio.charset.StandardCharsets.UTF_8);

        AttachmentContentInspector.Inspection result = AttachmentContentInspector.inspect(
                new ByteArrayInputStream(text), text.length, "note.txt", "text/plain");

        assertEquals(text.length, result.size());
    }
}
