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

    // ---- 2026-09-11 扩到办公常见类型：每种新类型都必须有自己的魔数把关 ----

    @Test
    void officeFamilyMagicBytesArePinnedPerContainer() {
        // OLE2 复合文档：ppt 与 doc/xls 同一套头
        accepts(ole2(), "方案.ppt", "application/vnd.ms-powerpoint");
        // OOXML 与 OpenDocument 都是 ZIP 容器
        accepts(zip(), "方案.pptx",
                "application/vnd.openxmlformats-officedocument.presentationml.presentation");
        accepts(zip(), "合同.odt", "application/vnd.oasis.opendocument.text");
        accepts(zip(), "台账.ods", "application/vnd.oasis.opendocument.spreadsheet");
        accepts(zip(), "方案.odp", "application/vnd.oasis.opendocument.presentation");
        accepts("{\\rtf1\\ansi 说明".getBytes(java.nio.charset.StandardCharsets.UTF_8),
                "说明.rtf", "application/rtf");

        // 换了容器就不认：pptx 声明配 OLE2 内容
        rejects(ole2(), "方案.pptx",
                "application/vnd.openxmlformats-officedocument.presentationml.presentation");
        // 扩展名与声明类型仍须一致
        rejects(ole2(), "方案.ppt", "application/msword");
    }

    @Test
    void textFamilyAcceptsCsvMarkdownXmlJsonAndStillRejectsHiddenBinary() {
        byte[] csv = "姓名,部门,金额\n张三,生产部,1200.50\n".getBytes(java.nio.charset.StandardCharsets.UTF_8);
        accepts(csv, "工资表.csv", "text/csv");
        accepts("# 说明\n- 第一条\n".getBytes(java.nio.charset.StandardCharsets.UTF_8),
                "说明.md", "text/markdown");
        accepts("{\"order\":\"XS-1\"}".getBytes(java.nio.charset.StandardCharsets.UTF_8),
                "接口.json", "application/json");
        accepts("<root><item/></root>".getBytes(java.nio.charset.StandardCharsets.UTF_8),
                "接口.xml", "text/xml");
        accepts("2026-09-11 启动完成\n".getBytes(java.nio.charset.StandardCharsets.UTF_8),
                "运行.log", "text/plain");

        byte[] sneaky = new byte[128];
        java.util.Arrays.fill(sneaky, (byte) 'a');
        sneaky[100] = 0x00;
        rejects(sneaky, "工资表.csv", "text/csv");
    }

    @Test
    void svgMustBeRealXmlAndNotAnyOtherTextFile() {
        accepts("<?xml version=\"1.0\"?><svg xmlns=\"http://www.w3.org/2000/svg\"/>"
                .getBytes(java.nio.charset.StandardCharsets.UTF_8), "图标.svg", "image/svg+xml");
        accepts("<svg viewBox=\"0 0 8 8\"></svg>".getBytes(java.nio.charset.StandardCharsets.UTF_8),
                "图标.svg", "image/svg+xml");
        // 是文本但不是 SVG：不给过（否则任何脚本文本都能借 image/ 类型进来）
        rejects("<html><body>hi</body></html>".getBytes(java.nio.charset.StandardCharsets.UTF_8),
                "图标.svg", "image/svg+xml");
        rejects("just text".getBytes(java.nio.charset.StandardCharsets.UTF_8),
                "图标.svg", "image/svg+xml");
    }

    @Test
    void uploadOnlyTypesStillNeedTheirMagicBytes() {
        // 这些类型只收不预览，但入库校验一视同仁
        accepts(new byte[] {0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00}, "扫描件.tif", "image/tiff");
        accepts(new byte[] {0x4d, 0x4d, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x08}, "扫描件.tiff", "image/tiff");
        accepts(new byte[] {0, 0, 0, 0x18, 'f', 't', 'y', 'p', 'h', 'e', 'i', 'c'}, "照片.heic", "image/heic");
        accepts(new byte[] {(byte) 0x37, (byte) 0x7a, (byte) 0xbc, (byte) 0xaf, 0x27, 0x1c},
                "资料.7z", "application/x-7z-compressed");
        accepts(new byte[] {'R', 'a', 'r', '!', 0x1a, 0x07, 0x01, 0x00}, "资料.rar", "application/vnd.rar");

        rejects(zip(), "资料.rar", "application/vnd.rar");
        rejects(new byte[] {0, 0, 0, 0x18, 'f', 't', 'y', 'p', 'q', 't', ' ', ' '},
                "照片.heic", "image/heic");
    }

    private static byte[] ole2() {
        byte[] header = new byte[64];
        byte[] magic = {(byte) 0xd0, (byte) 0xcf, 0x11, (byte) 0xe0,
                (byte) 0xa1, (byte) 0xb1, 0x1a, (byte) 0xe1};
        System.arraycopy(magic, 0, header, 0, magic.length);
        return header;
    }

    private static byte[] zip() {
        byte[] header = new byte[64];
        byte[] magic = {0x50, 0x4b, 0x03, 0x04};
        System.arraycopy(magic, 0, header, 0, magic.length);
        return header;
    }

    private static void accepts(byte[] bytes, String fileName, String contentType) {
        AttachmentContentInspector.Inspection result = AttachmentContentInspector.inspect(
                new ByteArrayInputStream(bytes), bytes.length, fileName, contentType);
        assertEquals(bytes.length, result.size(), fileName + " / " + contentType);
    }

    private static void rejects(byte[] bytes, String fileName, String contentType) {
        ApiException failure = assertThrows(ApiException.class, () ->
                AttachmentContentInspector.inspect(
                        new ByteArrayInputStream(bytes), bytes.length, fileName, contentType),
                fileName + " / " + contentType);
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
