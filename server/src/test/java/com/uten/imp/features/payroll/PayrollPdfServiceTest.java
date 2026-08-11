package com.uten.imp.features.payroll;

import com.uten.imp.features.payroll.dto.PayrollItemDto;
import com.uten.imp.features.payroll.dto.PayrollPdf;
import com.uten.imp.features.payroll.dto.PayrollSlipDto;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class PayrollPdfServiceTest {

    @Test
    void rendersCompletePdfWithValidCrossReferenceOffsets() {
        PayrollSlipDto slip = new PayrollSlipDto(
                UUID.randomUUID(),
                UUID.randomUUID(),
                "测试员工",
                "E001",
                2026,
                7,
                List.of(new PayrollItemDto(
                        "基本工资", new BigDecimal("10000.00"), "EARNING", null)),
                new BigDecimal("10000.00"),
                new BigDecimal("500.00"),
                new BigDecimal("9500.00"),
                "PUBLISHED",
                Instant.now(),
                null,
                null,
                null);

        PayrollPdf pdf = new PayrollPdfService().render(slip);
        String raw = new String(pdf.bytes(), StandardCharsets.ISO_8859_1);

        assertTrue(raw.startsWith("%PDF-1.4"));
        assertTrue(raw.contains("/Type /Page"));
        assertTrue(raw.contains("/UniGB-UCS2-H"));
        assertTrue(raw.endsWith("%%EOF\n"));
        assertEquals("payroll-2026-07-E001.pdf", pdf.filename());

        int xref = raw.indexOf("xref\n");
        String[] entries = raw.substring(xref).split("\\n");
        for (int object = 1; object <= 6; object++) {
            int offset = Integer.parseInt(entries[2 + object].substring(0, 10));
            assertTrue(raw.startsWith(object + " 0 obj", offset));
        }
    }
}
