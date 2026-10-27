package com.uten.imp.features.master.goods;

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
            new ExportColumn("name", "货品名称", ExportColumn.TEXT),
            new ExportColumn("code", "编号", ExportColumn.TEXT),
            new ExportColumn("categoryPath", "类别", ExportColumn.TEXT),
            new ExportColumn("spec", "规格", ExportColumn.TEXT),
            new ExportColumn("goodsId", "系统标识", ExportColumn.TEXT));
    private static final List<Map<String, Object>> ROWS = List.of(Map.of(
            "name", "原货品", "code", "OLD001", "categoryPath", "成品-电工", "spec", "10A", "goodsId", UUID.randomUUID().toString()));

    @Test
    void visibleColumnExportRetainsCategoryAndEditedTemplatePassesDetection() throws Exception {
        byte[] downloaded = downloadFromSystemExporter();

        try (var workbook = WorkbookFactory.create(new ByteArrayInputStream(downloaded));
             var edited = new ByteArrayOutputStream()) {
            var sheet = workbook.getSheetAt(0);
            assertEquals("类别", sheet.getRow(0).getCell(3).getStringCellValue());
            assertEquals("成品-电工", sheet.getRow(1).getCell(3).getStringCellValue());
            sheet.getRow(1).removeCell(sheet.getRow(1).getCell(0));
            sheet.getRow(1).createCell(0).setCellValue("新增货品");
            sheet.getRow(1).removeCell(sheet.getRow(1).getCell(1));
            sheet.getRow(1).createCell(1).setCellValue("");
            assertEquals("系统标识", sheet.getRow(0).getCell(4).getStringCellValue());
            sheet.getRow(1).removeCell(sheet.getRow(1).getCell(4));
            workbook.write(edited);
            try (var roundTrip = WorkbookFactory.create(new ByteArrayInputStream(edited.toByteArray()))) {
                assertEquals("新增货品", roundTrip.getSheetAt(0).getRow(1).getCell(0).getStringCellValue());
                assertEquals("", roundTrip.getSheetAt(0).getRow(1).getCell(1).getStringCellValue());
                assertNull(roundTrip.getSheetAt(0).getRow(1).getCell(4), "A new goods template must not retain the previous system UUID");
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
                for (var row : sheet) {
                    row.removeCell(row.getCell(1));
                    row.shiftCellsLeft(2, row.getLastCellNum() - 1, 1);
                }
            } else {
                // SXSSF exports inline strings. Replace the cell before editing
                // so POI cannot leave the original inline value beside a new value.
                var row = sheet.getRow(1);
                row.removeCell(row.getCell(1));
                row.createCell(1).setCellValue(incomingCode);
            }
            int idColumn = removeCodeColumn ? 3 : 4;
            assertEquals("系统标识", sheet.getRow(0).getCell(idColumn).getStringCellValue());
            assertEquals(ROWS.getFirst().get("goodsId"), sheet.getRow(1).getCell(idColumn).getStringCellValue(),
                    "The user must be able to retain a historical system identifier in an edited export");
            workbook.write(edited);
            file = edited.toByteArray();
        }
        try (var savedWorkbook = WorkbookFactory.create(new ByteArrayInputStream(file))) {
            var sheet = savedWorkbook.getSheetAt(0);
            if (removeCodeColumn) {
                assertEquals("规格", sheet.getRow(0).getCell(1).getStringCellValue());
                assertEquals("10A", sheet.getRow(1).getCell(1).getStringCellValue());
            } else {
                assertEquals(incomingCode, sheet.getRow(1).getCell(1).getStringCellValue(),
                        "The saved workbook must contain the user's edited number");
            }
            assertEquals(ROWS.getFirst().get("goodsId"),
                    sheet.getRow(1).getCell(removeCodeColumn ? 3 : 4).getStringCellValue());
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
        var importer = new GoodsImportService(goods, repository, null, categories,
                null, mock(ColorRepository.class), null, mock(UnitRepository.class), em, actor, null);

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
            assertEquals(List.of("规格", "货品名称", "编号", "类别", "系统标识"),
                    java.util.stream.IntStream.range(0, 5).mapToObj(i -> header.getCell(i).getStringCellValue()).toList());
        }
    }

    @Test
    void preservingRequiredColumnsDoesNotGrantSensitiveColumnAccess() {
        var projection = new TableColumnProjection("goods", "master_goods", List.of(
                new TableColumnProjection.Column("price", "价格", null, null, null)));
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

    private static GoodsImportService importer() {
        var categories = mock(MaterialCategoryRepository.class);
        when(categories.findByDeletedFalseOrderBySortOrderAscNameAsc()).thenReturn(List.of());
        var colors = mock(ColorRepository.class);
        when(colors.findAll()).thenReturn(List.of());
        var units = mock(UnitRepository.class);
        when(units.findAll()).thenReturn(List.of());
        var actor = mock(SecurityContextCurrentUser.class);
        when(actor.requireId()).thenReturn(UUID.randomUUID());
        return new GoodsImportService(null, mock(GoodsRepository.class), null, categories,
                null, colors, null, units, null, actor, null);
    }
}
