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
    void arbitraryLibraryOriginalsAreHashedWithoutChoosingAParserAndOtherOwnersStayRestricted() throws Exception {
        byte[] opaque = new byte[]{0, (byte) 0xff, 0x01, 'M', 'Z', 0, 0x7f};
        for (String name : java.util.List.of("设计原稿.CDR", "部件.step", "装配.sldasm", "无扩展名", "renamed.docx")) {
            var result = AttachmentContentInspector.inspectForOwner("COMPANY_FILE",
                    new ByteArrayInputStream(opaque), opaque.length, name, "application/octet-stream");
            assertEquals(HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(opaque)), result.sha256());
            assertEquals(opaque.length, result.size());
        }
        assertThrows(ApiException.class, () -> AttachmentContentInspector.inspectForOwner("SALES_ORDER",
                new ByteArrayInputStream(opaque), opaque.length, "设计.cdr", "application/octet-stream"));
        assertThrows(ApiException.class, () -> AttachmentContentInspector.inspectForOwner("COMPANY_FILE",
                new ByteArrayInputStream(opaque), opaque.length, "设计.cdr", "application/msword"));
        assertThrows(ApiException.class, () -> AttachmentContentInspector.inspectForOwner("COMPANY_FILE",
                new ByteArrayInputStream(opaque), opaque.length - 1L, "设计.cdr", "application/octet-stream"));
    }

    @Test
    void libraryMediaTypesCheckContainerAndExtensionWithoutWideningBusinessUploads() {
        var fixtures = java.util.Map.of(
                "video.mp4|video/mp4", new byte[]{0,0,0,24,'f','t','y','p','i','s','o','m'},
                "video.m4v|video/mp4", new byte[]{0,0,0,24,'f','t','y','p','M','4','V',' '},
                "video.mov|video/quicktime", new byte[]{0,0,0,24,'f','t','y','p','q','t',' ',' '},
                "video.webm|video/webm", new byte[]{0x1a,0x45,(byte)0xdf,(byte)0xa3,0x42,(byte)0x82,(byte)0x84,'w','e','b','m'},
                "audio.mp3|audio/mpeg", new byte[]{'I','D','3',4,0,0,0,0,0,0},
                "audio.wav|audio/wav", new byte[]{'R','I','F','F',0,0,0,0,'W','A','V','E'},
                "audio.ogg|audio/ogg", new byte[]{'O','g','g','S',0,0,0,0},
                "audio.oga|audio/ogg", new byte[]{'O','g','g','S',0,0,0,0});
        fixtures.forEach((key, bytes) -> {
            String[] parts = key.split("\\|");
            var recognized = AttachmentContentInspector.inspectForOwner("COMPANY_FILE",
                    new ByteArrayInputStream(bytes), bytes.length, parts[0], parts[1]);
            assertEquals(bytes.length, recognized.size());
            assertEquals(parts[1], recognized.effectiveContentType());
            assertThrows(ApiException.class, () -> AttachmentContentInspector.inspectForOwner("SALES_ORDER",
                    new ByteArrayInputStream(bytes), bytes.length, parts[0], parts[1]));
            byte[] fake = "not the declared media container".getBytes(java.nio.charset.StandardCharsets.US_ASCII);
            assertEquals("application/octet-stream", AttachmentContentInspector.inspectForOwner("COMPANY_FILE",
                    new ByteArrayInputStream(fake), fake.length, parts[0], parts[1]).effectiveContentType());
        });
    }

    @Test
    void unrecognizedMediaVariantsRemainOpaqueWithoutRelaxingTypedOfficeOrImageInspection() {
        byte[] legacyMov={0,0,0,8,'w','i','d','e',0,0,0,16,'m','d','a','t',0,1,2,3,4,5,6,7};
        byte[] av1Mp4={0,0,0,24,'f','t','y','p','a','v','0','1',0,0,0,0,'a','v','0','1','i','s','o','m'};
        for(var original:java.util.Map.of("legacy.mov|video/quicktime",legacyMov,"av1.mp4|video/mp4",av1Mp4).entrySet()) {
            String[] parts=original.getKey().split("\\|");byte[] bytes=original.getValue();
            var result=AttachmentContentInspector.inspectForOwner("COMPANY_FILE",new ByteArrayInputStream(bytes),bytes.length,parts[0],parts[1]);
            assertEquals("application/octet-stream",result.effectiveContentType());
            assertEquals(bytes.length,result.size());
        }
        assertThrows(ApiException.class,()->AttachmentContentInspector.inspectForOwner("COMPANY_FILE",
                new ByteArrayInputStream(legacyMov),legacyMov.length,"not-image.png","image/png"));
        assertThrows(ApiException.class,()->AttachmentContentInspector.inspectForOwner("COMPANY_FILE",
                new ByteArrayInputStream(legacyMov),legacyMov.length,"not-office.docx",
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document"));
    }

    @Test
    void aMediaDowngradeOnlyRelaxesTheCompanyMediaMimeBinding() {
        var owner=java.util.UUID.randomUUID();var actor=java.util.UUID.randomUUID();
        var grant=new AttachmentUploadGrantService.Grant("immutable-key","COMPANY_FILE",owner,actor,
                "legacy.mov","video/quicktime",24,java.time.Instant.now().plusSeconds(60));
        var attachment=new Attachment();attachment.setStorageKey(grant.storageKey());attachment.setOwnerType(grant.ownerType());
        attachment.setOwnerId(owner);attachment.setOriginalName(grant.originalName());attachment.setSizeBytes(grant.sizeBytes());
        attachment.setContentType("application/octet-stream");
        org.junit.jupiter.api.Assertions.assertTrue(AttachmentService.sameBinding(attachment,grant));
        attachment.setOriginalName("different.mov");
        org.junit.jupiter.api.Assertions.assertFalse(AttachmentService.sameBinding(attachment,grant));
        attachment.setOriginalName(grant.originalName());attachment.setSizeBytes(25);
        org.junit.jupiter.api.Assertions.assertFalse(AttachmentService.sameBinding(attachment,grant));
        attachment.setSizeBytes(grant.sizeBytes());attachment.setOwnerId(java.util.UUID.randomUUID());
        org.junit.jupiter.api.Assertions.assertFalse(AttachmentService.sameBinding(attachment,grant));
        attachment.setOwnerId(owner);attachment.setStorageKey("another-key");
        org.junit.jupiter.api.Assertions.assertFalse(AttachmentService.sameBinding(attachment,grant));
        attachment.setStorageKey(grant.storageKey());
        var imageGrant=new AttachmentUploadGrantService.Grant(grant.storageKey(),grant.ownerType(),owner,actor,
                grant.originalName(),"image/png",grant.sizeBytes(),grant.expiresAt());
        org.junit.jupiter.api.Assertions.assertFalse(AttachmentService.sameBinding(attachment,imageGrant));
        attachment.setOwnerType("SALES_ORDER");
        var businessGrant=new AttachmentUploadGrantService.Grant(grant.storageKey(),attachment.getOwnerType(),owner,actor,
                grant.originalName(),grant.contentType(),grant.sizeBytes(),grant.expiresAt());
        org.junit.jupiter.api.Assertions.assertFalse(AttachmentService.sameBinding(attachment,businessGrant));
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
    void ofdOriginalRequiresMatchingExtensionAndZipContainer() {
        accepts(zip(), "电子发票.ofd", "application/ofd");
        rejects("<html>not an ofd</html>".getBytes(java.nio.charset.StandardCharsets.UTF_8),
                "电子发票.ofd", "application/ofd");
        rejects(zip(), "电子发票.exe", "application/ofd");
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
