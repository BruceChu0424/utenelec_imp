package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.ExportLimitPort;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.*;
import com.uten.imp.common.platformcolumns.PlatformColumnService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.importing.GoodsImportService;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
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
        GoodsService goods = mock(GoodsService.class);
        when(goods.export(any(), nullable(String.class), nullable(String.class), eq(10000)))
                .thenReturn(new ExportPayload(COLUMNS, ROWS, 1));
        ExportLimitPort limits = mock(ExportLimitPort.class);
        when(limits.exportMaxRows()).thenReturn(10000);
        var controller = new GoodsController(goods, writer(), new WorkbookDownloadService(),
                mock(AuditService.class), mock(SecurityContextCurrentUser.class),
                mock(AuditDetailViewRecorder.class), limits);
        byte[] downloaded = MockMvcBuilders.standaloneSetup(controller).build().perform(
                post("/api/master/goods/export").contentType("application/json").content("""
                {"columnProjection":{"scope":"master_goods","columns":[
                  {"key":"name","label":"货品名称"},{"key":"code","label":"编号"},
                  {"key":"spec","label":"规格"}]}}
                """))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsByteArray();

        try (var workbook = WorkbookFactory.create(new ByteArrayInputStream(downloaded));
             var edited = new ByteArrayOutputStream()) {
            var sheet = workbook.getSheetAt(0);
            assertEquals("类别", sheet.getRow(0).getCell(3).getStringCellValue());
            assertEquals("成品-电工", sheet.getRow(1).getCell(3).getStringCellValue());
            sheet.getRow(1).getCell(0).setCellValue("新增货品");
            sheet.getRow(1).getCell(1).setCellValue("");
            assertEquals("系统标识", sheet.getRow(0).getCell(4).getStringCellValue());
            sheet.getRow(1).removeCell(sheet.getRow(1).getCell(4));
            workbook.write(edited);
            try (var roundTrip = WorkbookFactory.create(new ByteArrayInputStream(edited.toByteArray()))) {
                assertNull(roundTrip.getSheetAt(0).getRow(1).getCell(4), "A new goods template must not retain the previous system UUID");
            }
            var report = importer().detect(edited.toByteArray());
            assertTrue(report.errors().isEmpty(), () -> report.errors().toString());
            assertEquals(1, report.readyToImport());
            assertNotNull(report.planId());
        }
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
