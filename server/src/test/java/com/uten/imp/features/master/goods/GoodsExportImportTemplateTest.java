package com.uten.imp.features.master.goods;

import com.uten.imp.support.GoodsImportIdentifierAvailabilityFixture;

import com.uten.imp.application.port.ExportLimitPort;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.*;
import com.uten.imp.common.platformcolumns.PlatformColumnService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import com.uten.imp.features.master.goods.importing.GoodsImportService;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.apache.poi.ss.usermodel.WorkbookFactory;
import org.apache.poi.ss.usermodel.Sheet;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** Real projected export bytes must still contain the goods import schema. */
class GoodsExportImportTemplateTest {
    private static final List<ExportColumn> COLUMNS = List.of(
            new ExportColumn("goodsId", "系统标识", ExportColumn.TEXT),
            new ExportColumn("bomRef", "组装信息ID", ExportColumn.TEXT),
            new ExportColumn("code", "编号", ExportColumn.TEXT),
            new ExportColumn("name", "货品名称", ExportColumn.TEXT),
            new ExportColumn("categoryPath", "类别", ExportColumn.TEXT),
            new ExportColumn("spec", "规格", ExportColumn.TEXT));
    private static final List<Map<String, Object>> ROWS = List.of(Map.of(
            "name", "原货品", "code", "OLD001", "categoryPath", "成品 / 电工", "spec", "10A",
            "goodsId", UUID.randomUUID().toString(), "bomRef", ""));

    @Test
    void visibleColumnExportRetainsCategoryAndEditedTemplatePassesDetection() throws Exception {
        byte[] downloaded = downloadFromSystemExporter();

        try (var workbook = WorkbookFactory.create(new ByteArrayInputStream(downloaded));
             var edited = new ByteArrayOutputStream()) {
            var sheet = workbook.getSheetAt(0);
            assertEquals(List.of("系统标识", "组装信息ID", "编号"),
                    java.util.stream.IntStream.range(0, 3).mapToObj(i -> sheet.getRow(0).getCell(i).getStringCellValue()).toList());
            assertEquals("成品 / 电工", sheet.getRow(1).getCell(columnIndex(sheet, "类别")).getStringCellValue());
            int nameColumn = columnIndex(sheet, "货品名称"), codeColumn = columnIndex(sheet, "编号");
            sheet.getRow(1).removeCell(sheet.getRow(1).getCell(nameColumn));
            sheet.getRow(1).createCell(nameColumn).setCellValue("新增货品");
            sheet.getRow(1).removeCell(sheet.getRow(1).getCell(codeColumn));
            sheet.getRow(1).createCell(codeColumn).setCellValue("");
            sheet.getRow(1).removeCell(sheet.getRow(1).getCell(columnIndex(sheet, "系统标识")));
            workbook.write(edited);
            try (var roundTrip = WorkbookFactory.create(new ByteArrayInputStream(edited.toByteArray()))) {
                var saved = roundTrip.getSheetAt(0);
                assertEquals("新增货品", saved.getRow(1).getCell(nameColumn).getStringCellValue());
                assertEquals("", saved.getRow(1).getCell(codeColumn).getStringCellValue());
                assertNull(saved.getRow(1).getCell(columnIndex(saved, "系统标识")), "A new goods template must not retain the previous system UUID");
            }
            var report = importer().detect(edited.toByteArray());
            assertTrue(report.errors().isEmpty(), () -> report.errors().toString());
            assertEquals(1, report.readyToImport());
            assertNotNull(report.planId());
        }
    }

    @Test
    void historicalSystemExportWithChangedCodeCreatesGoodsInTheCurrentSystem() throws Exception {
        assertHistoricalSystemExportCanBeImported("NEW001", false);
    }

    @Test
    void historicalSystemExportWithBlankCodeUsesAutomaticCodeAllocation() throws Exception {
        assertHistoricalSystemExportCanBeImported("", false);
    }

    @Test
    void historicalSystemExportWithoutCodeColumnUsesAutomaticCodeAllocation() throws Exception {
        assertHistoricalSystemExportCanBeImported(null, true);
    }

    private static void assertHistoricalSystemExportCanBeImported(String incomingCode, boolean removeCodeColumn)
            throws Exception {
        byte[] file;
        try (var workbook = WorkbookFactory.create(new ByteArrayInputStream(downloadFromSystemExporter()));
             var edited = new ByteArrayOutputStream()) {
            var sheet = workbook.getSheetAt(0);
            if (removeCodeColumn) {
                int codeColumn = columnIndex(sheet, "编号");
                for (var row : sheet) {
                    row.removeCell(row.getCell(codeColumn));
                    row.shiftCellsLeft(codeColumn + 1, row.getLastCellNum() - 1, 1);
                }
            } else {
                // SXSSF exports inline strings. Replace the cell before editing
                // so POI cannot leave the original inline value beside a new value.
                var row = sheet.getRow(1);
                int codeColumn = columnIndex(sheet, "编号");
                row.removeCell(row.getCell(codeColumn));
                row.createCell(codeColumn).setCellValue(incomingCode);
            }
            assertEquals(ROWS.getFirst().get("goodsId"), sheet.getRow(1).getCell(columnIndex(sheet, "系统标识")).getStringCellValue(),
                    "The user must be able to retain a historical system identifier in an edited export");
            workbook.write(edited);
            file = edited.toByteArray();
        }
        try (var savedWorkbook = WorkbookFactory.create(new ByteArrayInputStream(file))) {
            var sheet = savedWorkbook.getSheetAt(0);
            if (removeCodeColumn) {
                assertEquals("10A", sheet.getRow(1).getCell(columnIndex(sheet, "规格")).getStringCellValue());
            } else {
                assertEquals(incomingCode, sheet.getRow(1).getCell(columnIndex(sheet, "编号")).getStringCellValue(),
                        "The saved workbook must contain the user's edited number");
            }
            assertEquals(ROWS.getFirst().get("goodsId"),
                    sheet.getRow(1).getCell(columnIndex(sheet, "系统标识")).getStringCellValue());
        }

        var goods = mock(GoodsService.class);
        UUID localGoodsId = UUID.randomUUID();
        when(goods.saveImported(any())).thenReturn(localGoodsId);
        var categories = mock(MaterialCategoryRepository.class);
        var root = new MaterialCategory();
        root.setId(UUID.randomUUID()); root.setName("成品");
        var category = new MaterialCategory();
        category.setId(UUID.randomUUID()); category.setName("电工"); category.setParent(root);
        when(categories.findByDeletedFalseOrderBySortOrderAscNameAsc()).thenReturn(List.of(root, category));
        var em = mock(EntityManager.class);
        var query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        var actor = mock(SecurityContextCurrentUser.class);
        when(actor.requireId()).thenReturn(UUID.randomUUID());
        var repository = mock(GoodsRepository.class);
        var importer = GoodsImportIdentifierAvailabilityFixture.allowAll(new GoodsImportService(goods, repository, null, categories,
                null, mock(ColorRepository.class), null, mock(UnitRepository.class), em, actor, null));

        var report = importer.detect(file);
        assertTrue(report.errors().isEmpty(), () -> report.errors().toString());
        assertEquals(1, report.addedRows());
        assertEquals(0, report.restorableRows());
        assertEquals(0, report.conflictRows());
        assertNotNull(report.planId());
        var result = importer.commit(report.planId(), file, "historical-system-export.xlsx");
        assertEquals(1, result.createdCount());
        assertEquals(1, result.importedCount());
        var saved = org.mockito.ArgumentCaptor.forClass(GoodsSaveRequest.class);
        verify(goods).saveImported(saved.capture());
        assertEquals(incomingCode, saved.getValue().getCode());
        assertEquals("原货品", saved.getValue().getName());
        assertEquals("10A", saved.getValue().getSpec());
        assertEquals(category.getId(), saved.getValue().getCategoryId());
        verify(repository, atLeastOnce()).findById(UUID.fromString(ROWS.getFirst().get("goodsId").toString()));
        verify(goods, never()).updateImported(any(), any());
        verify(goods, never()).restoreImported(any(), any());
        verify(query).setParameter("e", localGoodsId);
    }

    @Test
    void hiddenOrRenamedRequiredColumnsStillUseRecognizableImportHeaders() throws Exception {
        var projection = new TableColumnProjection("goods", "master_goods", List.of(
                new TableColumnProjection.Column("spec", "规格", null, null, null),
                new TableColumnProjection.Column("name", "产品", null, null, null)));
        var normalized = GoodsExportProjection.forImportTemplate(projection);
        byte[] bytes = writer().build(COLUMNS, ROWS, normalized, "master_goods");
        try (var workbook = WorkbookFactory.create(new ByteArrayInputStream(bytes))) {
            var header = workbook.getSheetAt(0).getRow(0);
            assertEquals(List.of("系统标识", "组装信息ID", "编号", "规格", "货品名称", "类别"),
                    java.util.stream.IntStream.range(0, 6).mapToObj(i -> header.getCell(i).getStringCellValue()).toList());
        }
    }

    @Test
    void preservingRequiredColumnsDoesNotGrantSensitiveColumnAccess() {
        for (String key : List.of("price", "discount")) {
            var projection = new TableColumnProjection("goods", "master_goods", List.of(
                    new TableColumnProjection.Column(key, "敏感列", null, null, null)));
            assertThrows(ApiException.class, () -> writer().build(COLUMNS, ROWS,
                    GoodsExportProjection.forImportTemplate(projection), "master_goods"));
        }
    }

    @Test
    void userHeaderOrderSurvivesRequiredImportColumnCompletion() throws Exception {
        var projection = new TableColumnProjection("goods", "master_goods", List.of(
                new TableColumnProjection.Column("code", "编号", null, null, null),
                new TableColumnProjection.Column("spec", "规格", null, null, null),
                new TableColumnProjection.Column("name", "货品名称", null, null, null)));
        byte[] bytes = writer().build(COLUMNS, ROWS,
                GoodsExportProjection.forImportTemplate(projection), "master_goods");
        try (var workbook = WorkbookFactory.create(new ByteArrayInputStream(bytes))) {
            var header = workbook.getSheetAt(0).getRow(0);
            assertEquals(List.of("系统标识", "组装信息ID", "编号", "规格", "货品名称", "类别"),
                    java.util.stream.IntStream.range(0, 6).mapToObj(i -> header.getCell(i).getStringCellValue()).toList());
        }
    }

    @Test
    void compatibilityExportWithoutScreenProjectionKeepsAllImportIdentityValues() throws Exception {
        byte[] bytes = writer().build(COLUMNS, ROWS, GoodsExportProjection.forImportTemplate(null), "master_goods");
        try (var workbook = WorkbookFactory.create(new ByteArrayInputStream(bytes))) {
            var sheet = workbook.getSheetAt(0);
            assertEquals(List.of("系统标识", "组装信息ID", "编号", "货品名称", "类别", "规格"),
                    java.util.stream.IntStream.range(0, 6).mapToObj(i -> sheet.getRow(0).getCell(i).getStringCellValue()).toList());
            assertEquals(ROWS.getFirst().get("goodsId"), sheet.getRow(1).getCell(0).getStringCellValue());
            assertEquals("OLD001", sheet.getRow(1).getCell(2).getStringCellValue());
        }
    }

    @Test
    void categoryFollowsGoodsNameEvenWhenScreenPlacesItElsewhere() throws Exception {
        for (var visible : List.of(
                List.of("name", "spec", "categoryPath"),
                List.of("categoryPath", "name", "spec"),
                List.of("name", "spec"),
                List.of("categoryPath", "spec"))) {
            var projection = new TableColumnProjection("goods", "master_goods", visible.stream()
                    .map(key -> new TableColumnProjection.Column(key,
                            "spec".equals(key) ? "规格" : "自定义标题", 180.0, null, null)).toList());
            var normalized = GoodsExportProjection.forImportTemplate(projection);
            byte[] bytes = writer().build(COLUMNS, ROWS, normalized, "master_goods");
            try (var workbook = WorkbookFactory.create(new ByteArrayInputStream(bytes))) {
                var sheet = workbook.getSheetAt(0);
                int name = columnIndex(sheet, "货品名称"), category = columnIndex(sheet, "类别");
                assertEquals(name + 1, category, visible.toString());
                assertEquals("原货品", sheet.getRow(1).getCell(name).getStringCellValue());
                assertEquals("成品 / 电工", sheet.getRow(1).getCell(category).getStringCellValue());
                assertEquals("10A", sheet.getRow(1).getCell(columnIndex(sheet, "规格")).getStringCellValue());
            }
            assertEquals(visible.contains("categoryPath") ? 180.0 : null,
                    normalized.columns().stream().filter(column -> "categoryPath".equals(column.key()))
                            .findFirst().orElseThrow().width());
        }
    }

    @Test
    void shuffledIdentityColumnsBecomeOneFixedPrefixWithoutMovingOtherScreenColumns() {
        var projection = new TableColumnProjection("goods", "master_goods", List.of(
                new TableColumnProjection.Column("spec", "规格", 150.0, null, null),
                new TableColumnProjection.Column("code", "自定编号名", 120.0, null, null),
                new TableColumnProjection.Column("name", "产品", 220.0, null, null),
                new TableColumnProjection.Column("bomRef", "装配", null, null, null),
                new TableColumnProjection.Column("goodsId", "UUID", null, null, null)));
        var normalized = GoodsExportProjection.forImportTemplate(projection);
        assertEquals(List.of("goodsId", "bomRef", "code", "spec", "name", "categoryPath"),
                normalized.columns().stream().map(TableColumnProjection.Column::key).toList());
        assertEquals(120.0, normalized.columns().get(2).width());
        assertEquals(150.0, normalized.columns().get(3).width());
        var request = mock(com.uten.imp.application.port.ReportExportQuery.class);
        when(request.report()).thenReturn("goods");
        when(request.columnProjection()).thenReturn(projection);
        var asyncSource = mock(com.uten.imp.features.master.export.MasterReportExportSource.class, CALLS_REAL_METHODS);
        assertEquals(normalized, asyncSource.projection(request), "Async and direct goods exports share the identity prefix contract");
    }

    @Test
    void duplicateIdentityColumnsAreStillRejectedBySharedValidation() {
        var projection = new TableColumnProjection("goods", "master_goods", List.of(
                new TableColumnProjection.Column("code", "编号", null, null, null),
                new TableColumnProjection.Column("code", "重复编号", null, null, null)));
        assertSame(projection, GoodsExportProjection.forImportTemplate(projection));
        assertThrows(ApiException.class, () -> writer().build(COLUMNS, ROWS,
                GoodsExportProjection.forImportTemplate(projection), "master_goods"));
    }

    private static byte[] downloadFromSystemExporter() throws Exception {
        GoodsService goods = mock(GoodsService.class);
        when(goods.export(any(), nullable(String.class), nullable(String.class), eq(10000)))
                .thenReturn(new ExportPayload(COLUMNS, ROWS, 1));
        ExportLimitPort limits = mock(ExportLimitPort.class);
        when(limits.exportMaxRows()).thenReturn(10000);
        var controller = new GoodsController(goods, writer(), new WorkbookDownloadService(),
                mock(AuditService.class), mock(SecurityContextCurrentUser.class),
                mock(AuditDetailViewRecorder.class), limits);
        return MockMvcBuilders.standaloneSetup(controller).build().perform(
                post("/api/master/goods/export").contentType("application/json").content("""
                {"columnProjection":{"scope":"master_goods","columns":[
                  {"key":"name","label":"货品名称"},{"key":"code","label":"编号"},
                  {"key":"spec","label":"规格"}]}}
                """))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsByteArray();
    }

    private static XlsxExportService writer() {
        var service = new XlsxExportService();
        @SuppressWarnings("unchecked")
        ObjectProvider<ExportTableProjectionService> provider = mock(ObjectProvider.class);
        when(provider.getObject()).thenReturn(new ExportTableProjectionService(mock(PlatformColumnService.class)));
        ReflectionTestUtils.setField(service, "projections", provider);
        return service;
    }

    private static int columnIndex(Sheet sheet, String label) {
        for (var cell : sheet.getRow(0)) {
            if (label.equals(cell.getStringCellValue())) return cell.getColumnIndex();
        }
        throw new AssertionError("Missing exported header: " + label);
    }

    private static GoodsImportService importer() {
        var categories = mock(MaterialCategoryRepository.class);
        when(categories.findByDeletedFalseOrderBySortOrderAscNameAsc()).thenReturn(List.of());
        var colors = mock(ColorRepository.class);
        when(colors.findAll()).thenReturn(List.of());
        var units = mock(UnitRepository.class);
        when(units.findAll()).thenReturn(List.of());
        var actor = mock(SecurityContextCurrentUser.class);
        when(actor.requireId()).thenReturn(UUID.randomUUID());
        return GoodsImportIdentifierAvailabilityFixture.allowAll(new GoodsImportService(null, mock(GoodsRepository.class), null, categories,
                null, colors, null, units, null, actor, null));
    }
}
