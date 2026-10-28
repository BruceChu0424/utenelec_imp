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

/**
 * 分类路径分隔符契约（2026-10-28 起与导出「 / 」同口径）：
 * 「/」整串优先；名称含「-」不再与分隔符冲突；名称含「/」仍按歧义报错；
 * 不含「/」的老导出「-」文件按老口径兜底解析。
 */
class GoodsImportCategoryPathTest {
    @Test
    void wholeSlashPathResolvesExistingCategoryNamesContainingDashes() throws Exception {
        var root = category("成品", null);
        var child = category("80-N系列", root);
        var report = importer(List.of(root, child)).detect(workbook("成品 / 80-N系列"));
        assertTrue(report.errors().isEmpty(), () -> report.errors().toString());
        assertEquals(1, report.readyToImport());
        assertTrue(report.willCreateCategories().isEmpty(), "must bind existing UUID chain rather than create 80/N系列");
        assertEquals(List.of("成品", "80-N系列"), report.previewRows().getFirst().categorySegments());
    }

    @Test
    void collidingFlatAndNestedNamesRejectAmbiguousSlashExportPaths() throws Exception {
        var root = category("成品", null);
        var flat = category("80/N", root);
        var nested = category("80", root);
        var leaf = category("N", nested);
        var report = importer(List.of(root, flat, nested, leaf)).detect(workbook("成品 / 80 / N"));
        assertEquals(0, report.readyToImport());
        assertEquals("类别", report.errors().getFirst().column());
        assertTrue(report.errors().getFirst().message().contains("路径重合"));
        assertNull(report.planId());
    }

    @Test
    void newDescendantKeepsExistingDashBearingAncestorIdentity() throws Exception {
        var root = category("成品", null);
        var parent = category("80-N", root);
        var report = importer(List.of(root, parent)).detect(workbook("成品 / 80-N / 灰色"));
        assertTrue(report.errors().isEmpty(), () -> report.errors().toString());
        assertEquals(List.of("成品/80-N/灰色"), report.willCreateCategories());
        assertEquals(List.of("成品", "80-N", "灰色"), report.previewRows().getFirst().categorySegments());
    }

    @Test
    void legacyDashFilesStillResolveThroughTheDashWholePathIndex() throws Exception {
        var root = category("成品", null);
        var child = category("80-N系列", root);
        var report = importer(List.of(root, child)).detect(workbook("成品-80-N系列"));
        assertTrue(report.errors().isEmpty(), () -> report.errors().toString());
        assertTrue(report.willCreateCategories().isEmpty());
        assertEquals(List.of("成品", "80-N系列"), report.previewRows().getFirst().categorySegments());
    }

    @Test
    void legacyDashFileWhoseCategoryNameContainsSlashStillResolvesWhole() throws Exception {
        // 生产存量分类名本身含「/」（20A/45A开关功能件）：老导出「-」文件的整串
        // 路径必须按整串对上，不能因为名称里有「/」被当成新格式拆碎。
        var root = category("成品", null);
        var child = category("20A/45A开关功能件", root);
        var report = importer(List.of(root, child)).detect(workbook("成品-20A/45A开关功能件"));
        assertTrue(report.errors().isEmpty(), () -> report.errors().toString());
        assertTrue(report.willCreateCategories().isEmpty());
        assertEquals(List.of("成品", "20A/45A开关功能件"), report.previewRows().getFirst().categorySegments());
    }

    @Test
    void problemRowsRetainTheResolvedCategoryChainWithoutSplittingNamesAgain() throws Exception {
        var root = category("成品", null);
        var child = category("20A/45A开关功能件", root);
        String path = "成品-20A/45A开关功能件";
        var report = importer(List.of(root, child)).detect(workbook(path), java.util.Map.of(), java.util.Set.of(),
                java.util.Map.of(2, java.util.Map.of("name", "")));
        assertFalse(report.errors().isEmpty());
        assertEquals(path, report.previewRows().getFirst().cells().get("categoryPath"),
                "The original editable text is retained separately from resolved path segments");
        assertEquals(List.of("成品", "20A/45A开关功能件"), report.previewRows().getFirst().categorySegments());
    }

    @Test
    void legacyDashAmbiguityStillRejectsInsteadOfGuessing() throws Exception {
        var root = category("成品", null);
        var flat = category("80-N", root);
        var nested = category("80", root);
        var leaf = category("N", nested);
        var report = importer(List.of(root, flat, nested, leaf)).detect(workbook("成品-80-N"));
        assertEquals(0, report.readyToImport());
        assertTrue(report.errors().getFirst().message().contains("路径重合"));
        assertNull(report.planId());
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
