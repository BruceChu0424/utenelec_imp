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

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class WorkbookDownloadServiceTest {

    @BeforeAll
    static void registerBouncyCastle() {
        if (Security.getProvider(BouncyCastleProvider.PROVIDER_NAME) == null) {
            Security.addProvider(new BouncyCastleProvider());
        }
    }

    private final XlsxExportService xlsxExport = new XlsxExportService();
    private final WorkbookDownloadService download = new WorkbookDownloadService();

    private byte[] sampleWorkbook() {
        List<ExportColumn> columns = List.of(
                new ExportColumn("billNo", "单号", ExportColumn.TEXT),
                new ExportColumn("amount", "金额", ExportColumn.MONEY),
                new ExportColumn("qty", "数量", ExportColumn.NUMBER),
                new ExportColumn("date", "日期", ExportColumn.DATE));
        List<Map<String, Object>> rows = List.of(
                Map.of("billNo", "PO-001", "amount", new BigDecimal("1234.5"),
                        "qty", 10, "date", "2024-03-15"),
                Map.of("billNo", "PO-002", "amount", new BigDecimal("99"),
                        "qty", 7, "date", "2024-03-16"));
        return xlsxExport.build(columns, rows);
    }

    @Test
    void emptyOrMissingPasswordReturnsPlainWorkbook() throws Exception {
        byte[] workbook = sampleWorkbook();

        assertArrayEquals(workbook, download.protect(workbook, null));
        assertArrayEquals(workbook, download.protect(workbook, ""));
        try (Workbook opened = WorkbookFactory.create(
                new ByteArrayInputStream(download.protect(workbook, "")))) {
            assertEquals("PO-001", opened.getSheetAt(0).getRow(1).getCell(0).getStringCellValue());
        }
    }

    @Test
    void oneCharacterPasswordEncryptsAndOpens() throws Exception {
        byte[] encrypted = download.protect(sampleWorkbook(), "1");

        try (Workbook opened = WorkbookFactory.create(new ByteArrayInputStream(encrypted), "1")) {
            assertEquals("单号", opened.getSheetAt(0).getRow(0).getCell(0).getStringCellValue());
            assertEquals(1234.5, opened.getSheetAt(0).getRow(1).getCell(1).getNumericCellValue(), 0.001);
        }
    }

    @Test
    void wrongPasswordCannotOpenEncryptedWorkbook() {
        byte[] encrypted = download.protect(sampleWorkbook(), "weak");

        assertThrows(Exception.class,
                () -> WorkbookFactory.create(new ByteArrayInputStream(encrypted), "wrong"));
    }

    @Test
    void passwordLongerThanLimitIsRejected() {
        assertThrows(IllegalArgumentException.class,
                () -> download.protect(sampleWorkbook(), "x".repeat(129)));
    }
}
