package com.uten.imp.common.export;

import org.apache.poi.ss.usermodel.Workbook;
import org.apache.poi.ss.usermodel.WorkbookFactory;
import org.bouncycastle.jce.provider.BouncyCastleProvider;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayInputStream;
import java.math.BigDecimal;
import java.security.Security;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

/**
 * 加密导出往返：明文 .xlsx → Agile AES-256 加密 → 正确密码读回校验数据、错密码失败。
 * 注册 BC provider（生产由 BouncyCastleRegistrar 在启动注册；纯单测这里手动注册一次）。
 */
class EncryptedWorkbookServiceTest {

    @BeforeAll
    static void registerBc() {
        if (Security.getProvider(BouncyCastleProvider.PROVIDER_NAME) == null) {
            Security.addProvider(new BouncyCastleProvider());
        }
    }

    private final XlsxExportService xlsx = new XlsxExportService();
    private final EncryptedWorkbookService enc = new EncryptedWorkbookService();

    private byte[] sampleXlsx() {
        List<ExportColumn> cols = List.of(
                new ExportColumn("billNo", "单号", ExportColumn.TEXT),
                new ExportColumn("amount", "金额", ExportColumn.MONEY),
                new ExportColumn("qty", "数量", ExportColumn.NUMBER),
                new ExportColumn("d", "日期", ExportColumn.DATE));
        List<Map<String, Object>> rows = List.of(
                Map.of("billNo", "PO-001", "amount", new BigDecimal("1234.5"), "qty", 10, "d", "2024-03-15"),
                Map.of("billNo", "PO-002", "amount", new BigDecimal("99"), "qty", 7, "d", "2024-03-16"));
        return xlsx.build(cols, rows);
    }

    @Test
    void correctPasswordOpensAndDataMatches() throws Exception {
        byte[] encrypted = enc.encrypt(sampleXlsx(), "secret123");
        try (Workbook wb = WorkbookFactory.create(new ByteArrayInputStream(encrypted), "secret123")) {
            var sheet = wb.getSheetAt(0);
            assertEquals("单号", sheet.getRow(0).getCell(0).getStringCellValue()); // 表头
            assertEquals("PO-001", sheet.getRow(1).getCell(0).getStringCellValue()); // 首行单号
            assertEquals(1234.5, sheet.getRow(1).getCell(1).getNumericCellValue(), 0.001); // 金额数值
        }
    }

    @Test
    void wrongPasswordFails() {
        byte[] encrypted = enc.encrypt(sampleXlsx(), "secret123");
        assertThrows(Exception.class,
                () -> WorkbookFactory.create(new ByteArrayInputStream(encrypted), "wrong-pwd"));
    }

    @Test
    void emptyPasswordRejected() {
        assertThrows(IllegalArgumentException.class, () -> enc.encrypt(sampleXlsx(), ""));
    }
}
