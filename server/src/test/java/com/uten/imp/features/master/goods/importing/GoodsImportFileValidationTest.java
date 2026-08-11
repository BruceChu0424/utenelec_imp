package com.uten.imp.features.master.goods.importing;

import com.uten.imp.common.web.ApiException;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Locks the user-facing validation contract for malformed import workbooks. */
class GoodsImportFileValidationTest {

    private final GoodsImportService service = new GoodsImportService(
            null, null, null, null, null, null, null, null, null, null);

    @Test
    void detect_rejectsEmptyFileWithRecoveryMessage() {
        ApiException error = assertThrows(ApiException.class, () -> service.detect(new byte[0]));

        assertTrue(error.getMessage().contains("文件为空"));
    }

    @Test
    void detect_rejectsLegacyOrEncryptedOleContainer() {
        byte[] oleHeader = new byte[]{
                (byte) 0xD0, (byte) 0xCF, 0x11, (byte) 0xE0,
                (byte) 0xA1, (byte) 0xB1, 0x1A, (byte) 0xE1
        };

        ApiException error = assertThrows(ApiException.class, () -> service.detect(oleHeader));

        assertTrue(error.getMessage().contains("未加密的 .xlsx"));
    }

    @Test
    void detect_convertsCorruptZipParserFailureToValidationError() {
        byte[] corruptZip = new byte[]{0x50, 0x4B, 0x03, 0x04, 0x00, 0x00};

        ApiException error = assertThrows(ApiException.class, () -> service.detect(corruptZip));

        assertTrue(error.getMessage().contains("无法"));
        assertTrue(error.getMessage().contains("未加密的 .xlsx"));
    }

    @Test
    void detect_rejectsWorkbookWithoutSheets() throws Exception {
        byte[] workbookBytes;
        try (XSSFWorkbook workbook = new XSSFWorkbook();
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            workbook.write(output);
            workbookBytes = output.toByteArray();
        }

        ApiException error = assertThrows(ApiException.class, () -> service.detect(workbookBytes));

        assertTrue(error.getMessage().contains("不包含工作表"));
    }
}
