package com.uten.imp.features.sales.intake;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiCompletionPort;
import com.uten.imp.application.port.MasterIntakeLookupPort;
import com.uten.imp.common.files.document.SpreadsheetGridReader;
import com.uten.imp.common.web.ApiError;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.apache.poi.hssf.usermodel.HSSFWorkbook;
import org.apache.poi.ss.usermodel.Workbook;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.util.Optional;
import java.util.Random;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.*;

/** Page attachment recognition must enforce complete input even without ERP_DOCUMENT_ROUTE. */
class SalesIntakePartialSourceTest {
    private final MasterIntakeLookupPort lookup = mock(MasterIntakeLookupPort.class);
    private final IntakeReferenceData data = mock(IntakeReferenceData.class);
    private final AiCompletionPort ai = mock(AiCompletionPort.class);
    private final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
    private final SalesDocumentIntakeJobHandler handler = new SalesDocumentIntakeJobHandler(
            lookup, data, new ObjectMapper(), ai, current, Clock.systemUTC());

    @ParameterizedTest
    @ValueSource(strings = {"XLSX", "XLS", "CSV"})
    void directSalesRecognitionRejectsOverlongCellBeforeModelMatchingOrLearning(String kind) throws Exception {
        byte[] input;
        if (kind.equals("CSV")) {
            input = ("货品编码,数量,备注\nMAT-1,2," + longCell()).getBytes(StandardCharsets.UTF_8);
        } else {
            try (Workbook workbook = kind.equals("XLS") ? new HSSFWorkbook() : new XSSFWorkbook()) {
                table(workbook, "客户订货");
                workbook.getSheetAt(0).getRow(1).createCell(2).setCellValue(longCell());
                input = bytes(workbook);
            }
        }
        var context = context("direct." + kind.toLowerCase(java.util.Locale.ROOT), kind, input);
        ApiException failure = assertThrows(ApiException.class, () -> handler.process(context));
        assertThat(failure.getFieldErrors()).contains(new ApiError.FieldError("errorCode", "PARTIAL_SOURCE"));
        assertThat(failure.getMessage()).contains("拆分", "未导入任何明细");
        noDownstream(context);
    }

    @Test void selectingCleanSheetCannotHideTruncationInAnotherVisibleSheet() throws Exception {
        byte[] input;
        try (Workbook workbook = new XSSFWorkbook()) {
            table(workbook, "完整订货表");
            workbook.createSheet("附录").createRow(0).createCell(0).setCellValue(longCell());
            input = bytes(workbook);
        }
        var context = context("selected.xlsx", "XLSX", input);
        context.params.put("sheet", "0");
        ApiException failure = assertThrows(ApiException.class, () -> handler.process(context));
        assertThat(failure.getFieldErrors()).contains(new ApiError.FieldError("errorCode", "PARTIAL_SOURCE"));
        noDownstream(context);
    }

    @Test void ninthVisibleSheetIsRejectedByTheDirectSalesEntryRatherThanIgnoringTheTail() throws Exception {
        byte[] input;
        try (Workbook workbook = new XSSFWorkbook()) {
            for (int sheet = 0; sheet <= SpreadsheetGridReader.MAX_SHEETS; sheet++) table(workbook, "订货" + sheet);
            input = bytes(workbook);
        }
        var context = context("nine.xlsx", "XLSX", input);
        ApiException failure = assertThrows(ApiException.class, () -> handler.process(context));
        assertThat(failure.getMessage()).contains("超过 8 个可见工作表", "拆分");
        noDownstream(context);
    }

    private FakeJobContext context(String name, String kind, byte[] bytes) {
        var context = FakeJobContext.of(name, kind, bytes, "quote");
        context.aiAllowed = true;
        when(current.get()).thenReturn(Optional.of(new AuthUser(context.submittedByUser(), UUID.randomUUID(),
                "direct-intake-test", Set.of("ai:use", "sales_quote:create"), false, true, false)));
        assertThat(context.kind()).isEqualTo(SalesDocumentIntakeJobHandler.KIND);
        handler.authorizeSubmit(context.params());
        handler.validateInput(context.params(), context.input());
        return context;
    }

    private void noDownstream(FakeJobContext context) {
        assertThat(context.stages).containsExactly("READING:10");
        assertThat(context.aiRequests).isEmpty();
        verifyNoInteractions(ai, lookup, data);
    }

    private static void table(Workbook workbook, String name) {
        var sheet = workbook.createSheet(name);
        var header = sheet.createRow(0);
        header.createCell(0).setCellValue("货品编码");
        header.createCell(1).setCellValue("数量");
        header.createCell(2).setCellValue("备注");
        var line = sheet.createRow(1);
        line.createCell(0).setCellValue("MAT-1");
        line.createCell(1).setCellValue(2);
    }

    private static byte[] bytes(Workbook workbook) throws Exception {
        try (var output = new ByteArrayOutputStream()) {
            workbook.write(output);
            return output.toByteArray();
        }
    }

    private static String longCell() {
        // Avoid triggering the unrelated ZIP inflation guard before the cell-length boundary.
        var random = new Random(41);
        var text = new StringBuilder();
        for (int i = 0; i <= SpreadsheetGridReader.MAX_CELL_CHARS; i++) text.append((char) ('a' + random.nextInt(26)));
        return text.toString();
    }
}
