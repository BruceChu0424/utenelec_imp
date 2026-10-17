package com.uten.imp.features.master.goods.importing;

import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.GoodsRepository;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class GoodsImportCategoryPathTest {
    @Test
    void wholeExportedPathResolvesExistingCategoryNamesContainingDashes() throws Exception {
        var root = category("成品", null);
        var child = category("80-N系列", root);
        var report = importer(List.of(root, child)).detect(workbook("成品-80-N系列"));
        assertTrue(report.errors().isEmpty(), () -> report.errors().toString());
        assertEquals(1, report.readyToImport());
        assertTrue(report.willCreateCategories().isEmpty(), "must bind existing UUID chain rather than create 80/N系列");
    }

    @Test
    void collidingFlatAndNestedNamesRejectAmbiguousExportPaths() throws Exception {
        var root = category("成品", null);
        var flat = category("80-N", root);
        var nested = category("80", root);
        var leaf = category("N", nested);
        var report = importer(List.of(root, flat, nested, leaf)).detect(workbook("成品-80-N"));
        assertEquals(0, report.readyToImport());
        assertEquals("类别", report.errors().getFirst().column());
        assertTrue(report.errors().getFirst().message().contains("路径重合"));
        assertNull(report.planId());
    }

    @Test
    void newDescendantKeepsExistingDashBearingAncestorIdentity() throws Exception {
        var root = category("成品", null);
        var parent = category("80-N", root);
        var report = importer(List.of(root, parent)).detect(workbook("成品-80-N-灰色"));
        assertTrue(report.errors().isEmpty(), () -> report.errors().toString());
        assertEquals(List.of("成品-80-N-灰色"), report.willCreateCategories());
    }

    private static MaterialCategory category(String name, MaterialCategory parent) {
        var category = new MaterialCategory();
        category.setName(name);
        category.setParent(parent);
        return category;
    }

    private static GoodsImportService importer(List<MaterialCategory> tree) {
        var categories = mock(MaterialCategoryRepository.class);
        when(categories.findByDeletedFalseOrderBySortOrderAscNameAsc()).thenReturn(tree);
        var colors = mock(ColorRepository.class);
        when(colors.findAll()).thenReturn(List.of());
        var units = mock(UnitRepository.class);
        when(units.findAll()).thenReturn(List.of());
        var actor = mock(SecurityContextCurrentUser.class);
        when(actor.requireId()).thenReturn(UUID.randomUUID());
        return new GoodsImportService(null, mock(GoodsRepository.class), null, categories,
                null, colors, null, units, null, actor, null);
    }

    private static byte[] workbook(String path) throws Exception {
        try (var workbook = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            var sheet = workbook.createSheet("货品");
            var header = sheet.createRow(0);
            header.createCell(0).setCellValue("编号");
            header.createCell(1).setCellValue("货品名称");
            header.createCell(2).setCellValue("类别");
            var row = sheet.createRow(1);
            row.createCell(0).setCellValue("");
            row.createCell(1).setCellValue("新货品");
            row.createCell(2).setCellValue(path);
            workbook.write(out);
            return out.toByteArray();
        }
    }
}
