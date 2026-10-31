package com.uten.imp.features.production.execution;

import com.uten.imp.application.port.ExportLimitPort;
import com.uten.imp.application.port.WorkshopTaskExportContract;
import com.uten.imp.common.export.*;
import com.uten.imp.common.web.*;
import com.uten.imp.features.reporting.export.*;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.*;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import java.io.ByteArrayInputStream;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import java.util.stream.IntStream;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class ProductionWorkshopTaskExportServiceTest {
    final ProductionExecutionWorkbenchService reader = mock(ProductionExecutionWorkbenchService.class);
    final ExportLimitPort limits = () -> 2000;
    final ProductionWorkshopTaskExportService exports = new ProductionWorkshopTaskExportService(reader, limits);
    final UUID workshop = UUID.randomUUID();
    @BeforeEach void login() {
        var actor = user(Set.of("production_execution:view", "production_report:export"));
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor, null, actor.getAuthorities()));
    }
    @AfterEach void logout() { SecurityContextHolder.clearContext(); }
    private static AuthUser user(Set<String> permissions) {
        return new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "fixture", permissions, false, true, false);
    }
    private ProductionExecutionWorkbenchSegment task(int n) {
        var task = mock(ProductionExecutionWorkbenchSegment.class);
        when(task.segmentId()).thenReturn(new UUID(0, n));
        when(task.segmentCode()).thenReturn("ZX" + n);
        when(task.productName()).thenReturn("导出产品");
        when(task.segmentStatus()).thenReturn("IN_PROGRESS");
        when(task.startRoute()).thenReturn("CONTINUOUS");
        when(task.plannedQty()).thenReturn(new BigDecimal("9999999999999.9999"));
        when(task.reportedQty()).thenReturn(new BigDecimal("0.0001"));
        when(task.productUnitName()).thenReturn("个");
        return task;
    }
    @Test void streamsAllPagesUsingExactlyTheOriginalTaskScopeAndFilters() {
        var from = LocalDate.of(2026, 10, 1); var to = LocalDate.of(2026, 10, 31);
        var p = Map.of("status", "COMPLETED", "keyword", "轨道", "workshopDepartmentId", workshop.toString(),
                "dateFrom", from.toString(), "dateTo", to.toString(), "analysisNo", "WL001", "segmentCode", "ZX001");
        for (int page = 1; page <= 3; page++) {
            int start = (page - 1) * 500, end = Math.min(1001, start + 500);
            var rows = IntStream.range(start, end).mapToObj(this::task).toList();
            when(reader.workshopTasks(page, 500, "轨道", "COMPLETED", workshop, from, to,
                    null, null, "WL001", "ZX001", "segment", "desc")).thenReturn(
                    new PageResponse<>(rows, page, 500, 1001, 3));
        }
        List<ExportPayload> batches = new ArrayList<>();
        try (var sink = ExportPageSink.open(batches::add)) {
            var result = exports.export(p, "segment", "desc");
            assertEquals(1001, result.total()); assertTrue(result.rows().isEmpty());
        }
        assertEquals(List.of(500, 500, 1), batches.stream().map(b -> b.rows().size()).toList());
        assertEquals(1001, batches.stream().flatMap(b -> b.rows().stream()).map(r -> r.get("segment")).distinct().count());
        verify(reader, times(3)).workshopTasks(anyInt(), eq(500), eq("轨道"), eq("COMPLETED"), eq(workshop),
                eq(from), eq(to), isNull(), isNull(), eq("WL001"), eq("ZX001"), eq("segment"), eq("desc"));
    }
    @Test void workbookPreservesExactQuantityUnitAndLiteralNames() throws Exception {
        var t = task(1); when(t.productName()).thenReturn("=HYPERLINK(unsafe)");
        var payload = new ExportPayload(ProductionWorkshopTaskExportService.columns("IN_PROGRESS"),
                List.of(ProductionWorkshopTaskExportService.row(t)), 1);
        byte[] bytes = new XlsxExportService().build(payload.columns(), payload.rows());
        try (var workbook = new org.apache.poi.xssf.usermodel.XSSFWorkbook(new ByteArrayInputStream(bytes))) {
            var sheet = workbook.getSheetAt(0);
            Map<String,Integer> indexes = new HashMap<>();
            sheet.getRow(0).forEach(c -> indexes.put(c.getStringCellValue(), c.getColumnIndex()));
            var row = sheet.getRow(1);
            assertEquals("=HYPERLINK(unsafe)", row.getCell(indexes.get("产品名称")).getStringCellValue());
            assertEquals(org.apache.poi.ss.usermodel.CellType.STRING, row.getCell(indexes.get("产品名称")).getCellType());
            var qty = row.getCell(indexes.entrySet().stream().filter(e -> e.getKey().startsWith("产品数量")).findFirst().orElseThrow().getValue());
            assertTrue(new org.apache.poi.ss.usermodel.DataFormatter().formatCellValue(qty).contains("9999999999999.9999"));
            assertEquals("报工 0.0001", row.getCell(indexes.get("实际产出")).getStringCellValue());
        }
    }
    @Test void needsBothExportAndTaskViewAndRejectsInvalidFilters() {
        var request = new ReportExportRequest(UUID.randomUUID(), "production", "workshop-tasks",
                Map.of("status", "IN_PROGRESS"), null, null, null);
        for (var permissions : List.of(Set.of("production_report:export"), Set.of("production_execution:view")))
            assertEquals(ErrorCode.FORBIDDEN, assertThrows(ApiException.class,
                    () -> ReportExportService.authorizeRequest(user(permissions), request)).getCode());
        ReportExportService.authorizeRequest(user(Set.of("production_execution:view", "production_report:export")), request);
        assertThrows(ApiException.class, () -> WorkshopTaskExportContract.validate(Map.of("status", "ALL"), null, null));
        assertThrows(ApiException.class, () -> WorkshopTaskExportContract.validate(Map.of("status", "IN_PROGRESS", "owner", "other"), null, null));
        assertThrows(ApiException.class, () -> WorkshopTaskExportContract.validate(Map.of("status", "COMPLETED",
                "dateFrom", "2026-10-31", "dateTo", "2026-10-01"), null, null));
        SecurityContextHolder.clearContext();
        assertThrows(ApiException.class, () -> exports.export(Map.of("status", "IN_PROGRESS"), null, null));
        verifyNoInteractions(reader);
    }
    @Test void materialSummaryKeepsBinAndDiscoveryFactsInsteadOfClaimingThereIsNoMaterial() {
        var task = task(1);
        when(task.binMaterialState()).thenReturn("NEED_BIN");
        assertEquals("车间内料仓未开启", ProductionWorkshopTaskExportService.row(task).get("material"));
        when(task.binMaterialState()).thenReturn("NEED_CHOICE");
        assertEquals("待认料 · 开工时选用料", ProductionWorkshopTaskExportService.row(task).get("material"));
        when(task.binMaterialState()).thenReturn("KNOWN");
        assertEquals("车间内料仓供料", ProductionWorkshopTaskExportService.row(task).get("material"));
        when(task.materialDiscoveryRequired()).thenReturn(true);
        when(task.materialDiscoveryStatus()).thenReturn("PENDING");
        assertEquals("待仓库填写物料", ProductionWorkshopTaskExportService.row(task).get("material"));
    }
}
