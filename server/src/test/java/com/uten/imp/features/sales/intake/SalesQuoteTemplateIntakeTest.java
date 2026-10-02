package com.uten.imp.features.sales.intake;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.MasterIntakeLookupPort;
import com.uten.imp.features.sales.template.QuoteTemplateWorkbook;
import org.apache.poi.ss.usermodel.WorkbookFactory;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.time.Clock;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class SalesQuoteTemplateIntakeTest {
    private final MasterIntakeLookupPort lookup = mock(MasterIntakeLookupPort.class);
    private final IntakeReferenceData data = mock(IntakeReferenceData.class);
    private final SalesIntakePipeline pipeline = new SalesIntakePipeline(lookup, data, new ObjectMapper(), () -> false, Clock.systemUTC());

    @Test void emptyTemplateUsesRulesWithoutMatchingGoodsPricesOrChangingMaster() throws Exception {
        var ctx = context(false, false);
        var result = pipeline.run(ctx);
        assertThat(result).containsEntry("templateOnly", true).containsEntry("layoutSource", "RULES");
        assertThat(result).doesNotContainKeys("lines", "client", "currency");
        assertThat(ctx.stages).noneMatch(stage -> stage.startsWith("MATCHING_") || stage.startsWith("PRICING"));
        assertThat(ctx.aiRequests).isEmpty();
        verifyNoInteractions(lookup);
        verify(data, never()).currencies();
        verify(data).stageTemplate(eq(ctx.jobId()), eq(ctx.submittedByUser()), eq("customer.xlsx"), any());
    }

    @Test void populatedTemplateIsSanitizedAndConfirmationContainsOnlyMapping() throws Exception {
        var ctx = context(true, false);
        var result = pipeline.run(ctx);
        assertThat(result.toString()).doesNotContain("CONFIDENTIAL CUSTOMER", "OLD GOODS", "12345678");
        var saved = ArgumentCaptor.forClass(QuoteTemplateWorkbook.Candidate.class);
        verify(data).stageTemplate(any(), any(), any(), saved.capture());
        try (var workbook = WorkbookFactory.create(new ByteArrayInputStream(saved.getValue().xlsx()))) {
            StringBuilder text = new StringBuilder();
            workbook.getSheetAt(0).forEach(row -> row.forEach(cell -> text.append(cell)));
            assertThat(text.toString()).doesNotContain("CONFIDENTIAL CUSTOMER", "OLD GOODS", "12345678");
        }
        verifyNoInteractions(lookup);
    }

    @Test void emptyUnfamiliarHeadersUseTheSameAiColumnRecognition() throws Exception {
        var ctx = context(false, true);
        ctx.aiAllowed = true;
        ctx.ai = request -> """
                {"headerRow":3,"columns":[{"column":"A","role":"PART_NO"},
                {"column":"B","role":"DESCRIPTION"},{"column":"C","role":"QTY"},{"column":"D","role":"UNIT_PRICE"}]}
                """;
        var result = pipeline.run(ctx);
        assertThat(result).containsEntry("layoutSource", "AI");
        assertThat(ctx.aiRequests).hasSize(1);
        verifyNoInteractions(lookup);
        verify(data).stageTemplate(any(), any(), any(), any());
    }

    @Test void failedStorageAndCancelledJobsNeverOfferASavableTemplate() throws Exception {
        var cancelled = context(false, false); cancelled.cancelled = true;
        assertThat(pipeline.run(cancelled)).isEmpty();
        verify(data, never()).stageTemplate(any(), any(), any(), any());
        doThrow(new IllegalStateException("storage unavailable")).when(data).stageTemplate(any(), any(), any(), any());
        var ctx = context(false, false);
        assertThatThrownBy(() -> pipeline.run(ctx)).hasMessageContaining("storage unavailable");
    }

    @Test void unfamiliarBlankTemplateWithoutAiFailsClearlyAndStagesNothing() throws Exception {
        var ctx = context(false, true);
        assertThatThrownBy(() -> pipeline.run(ctx)).hasMessageContaining("表");
        verify(data, never()).stageTemplate(any(), any(), any(), any());
        verifyNoInteractions(lookup);
    }

    @Test void templateModeCannotBeUsedForAnOrderOrWithoutDocumentAndClient() {
        assertThatThrownBy(() -> IntakeParams.parse(Map.of("docType", "quote", "templateOnly", "true"))).hasMessageContaining("已保存");
        assertThatThrownBy(() -> IntakeParams.parse(Map.of("docType", "order", "templateOnly", "true", "docId", UUID.randomUUID().toString(), "clientId", UUID.randomUUID().toString()))).hasMessageContaining("已保存");
        assertThatThrownBy(() -> IntakeParams.parse(Map.of("docType", "quote", "templateOnly", "TRUE"))).hasMessageContaining("参数");
    }

    private FakeJobContext context(boolean populated, boolean odd) throws Exception {
        byte[] bytes;
        try (var workbook = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            var sheet = workbook.createSheet("Customer format");
            sheet.createRow(0).createCell(0).setCellValue("CONFIDENTIAL CUSTOMER");
            String[] headers = odd ? new String[]{"Artikel", "Bezeichnung", "Menge", "Preis"} : new String[]{"Model", "Description", "Qty", "Unit Price"};
            var header = sheet.createRow(2);
            for (int i = 0; i < headers.length; i++) header.createCell(i).setCellValue(headers[i]);
            var row = sheet.createRow(3);
            if (populated) {
                row.createCell(0).setCellValue("ABC"); row.createCell(1).setCellValue("OLD GOODS");
                row.createCell(2).setCellValue(5); row.createCell(3).setCellValue(12345678);
            }
            workbook.write(out); bytes = out.toByteArray();
        }
        var ctx = FakeJobContext.of("customer.xlsx", "XLSX", bytes, "quote");
        ctx.params.putAll(Map.of("templateOnly", "true", "docId", UUID.randomUUID().toString(), "clientId", UUID.randomUUID().toString()));
        when(data.layouts(any(), any())).thenReturn(List.of());
        return ctx;
    }
}
