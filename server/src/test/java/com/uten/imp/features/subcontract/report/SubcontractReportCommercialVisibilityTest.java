package com.uten.imp.features.subcontract.report;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class SubcontractReportCommercialVisibilityTest {

    @Test
    void maskedResponseRemovesMoneyPriceSettlementRowsAndSortableColumns() {
        List<ReportColumn> columns = List.of(
                ReportColumn.text("goodsName", "货品"),
                ReportColumn.number("qty", "数量"),
                ReportColumn.money("price", "单价"),
                ReportColumn.money("amount", "金额"),
                new ReportColumn("settlementStyle", "结帐方式", "style", 100),
                ReportColumn.text("__srcId", ""));
        Object[] source = new Object[]{"材料", new BigDecimal("8"),
                new BigDecimal("10"), new BigDecimal("80"), 6, UUID.randomUUID()};

        List<ReportColumn> safeColumns =
                SubcontractReportService.responseColumns(columns, true);
        Map<String, Object> safeRow =
                SubcontractReportService.responseRow(columns, source, true);

        assertEquals(List.of("goodsName", "qty", "__srcId"),
                safeColumns.stream().map(ReportColumn::key).toList());
        assertEquals(new BigDecimal("8"), safeRow.get("qty"));
        assertFalse(safeRow.containsKey("price"));
        assertFalse(safeRow.containsKey("amount"));
        assertFalse(safeRow.containsKey("settlementStyle"));
        assertTrue(SubcontractReportService.isCommercialKey("settlementStyle"));
    }

    @Test
    void authorizedResponseRetainsCommercialColumnsAndValues() {
        List<ReportColumn> columns = List.of(
                ReportColumn.number("qty", "数量"),
                ReportColumn.money("price", "单价"),
                new ReportColumn("settlementStyle", "结帐方式", "style", 100));
        Object[] source = new Object[]{new BigDecimal("8"), new BigDecimal("10"), 6};

        assertEquals(columns, SubcontractReportService.responseColumns(columns, false));
        Map<String, Object> row = SubcontractReportService.responseRow(columns, source, false);
        assertEquals(new BigDecimal("10"), row.get("price"));
        assertTrue(row.containsKey("settlementStyle"));
    }

    @Test
    void monthlyRowKeepsQuantityButMasksAmount() {
        Object[] source = new Object[]{"RECEIPT", LocalDate.of(2026, 8, 1),
                UUID.randomUUID(), "G-1", "材料", UUID.randomUUID(),
                new BigDecimal("12"), new BigDecimal("360"), 3L};

        SubcontractMonthlyRow row = SubcontractReportService.monthlyRow(source, true);

        assertEquals(new BigDecimal("12"), row.getQty());
        assertNull(row.getAmt());
        assertTrue(row.isPriceMasked());
    }
}
