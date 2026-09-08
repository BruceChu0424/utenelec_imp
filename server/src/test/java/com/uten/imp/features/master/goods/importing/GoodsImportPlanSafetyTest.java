package com.uten.imp.features.master.goods.importing;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.color.Color;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.color.ColorService;
import com.uten.imp.features.master.color.dto.ColorDetail;
import com.uten.imp.features.master.goods.GoodsRepository;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.materialcategory.MaterialCategoryService;
import com.uten.imp.features.master.unit.Unit;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.features.master.unit.UnitService;
import com.uten.imp.features.master.unit.dto.UnitDetail;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class GoodsImportPlanSafetyTest {

    @Test
    void detectReturnsPlanOnlyForAnErrorFreeWorkbook() throws Exception {
        Fixtures fixtures = fixtures();
        byte[] workbook = workbook("", "导入货品", "成品", "红色", "个");

        GoodsImportReport report = fixtures.service.detect(workbook);

        assertTrue(report.errors().isEmpty());
        assertEquals(1, report.readyToImport());
        assertNotNull(report.planId());
    }

    @Test
    void commitRejectsDifferentWorkbookAndConsumesThePlan() throws Exception {
        Fixtures fixtures = fixtures();
        byte[] original = workbook("", "导入货品", "成品", "红色", "个");
        UUID planId = fixtures.service.detect(original).planId();
        byte[] changed = workbook("", "另一货品", "成品", "红色", "个");

        ApiException mismatch = assertThrows(
                ApiException.class,
                () -> fixtures.service.commit(planId, changed, "changed.xlsx"));
        assertTrue(mismatch.getMessage().contains("不一致"));

        ApiException replay = assertThrows(
                ApiException.class,
                () -> fixtures.service.commit(planId, original, "original.xlsx"));
        assertTrue(replay.getMessage().contains("已使用"));
    }

    @Test
    void detectFailsClosedWhenColorNameMapsToMultipleUuids() throws Exception {
        Fixtures fixtures = fixtures();
        Color first = color(UUID.randomUUID(), "红色");
        Color second = color(UUID.randomUUID(), "红色");
        when(fixtures.colors.findAll()).thenReturn(List.of(first, second));

        GoodsImportReport report = fixtures.service.detect(
                workbook("", "导入货品", "成品", "红色", "个"));

        assertNull(report.planId());
        assertTrue(report.errors().stream().anyMatch(
                error -> error.column().equals("主颜色") && error.message().contains("多个")));
    }

    @Test
    void commitRejectsMasterDriftAfterDetect() throws Exception {
        Fixtures fixtures = fixtures();
        byte[] workbook = workbook("", "导入货品", "成品", "红色", "个");
        UUID planId = fixtures.service.detect(workbook).planId();
        when(fixtures.units.findAll()).thenReturn(List.of(
                unit(fixtures.unitId, "个"), unit(UUID.randomUUID(), "箱")));

        ApiException error = assertThrows(
                ApiException.class,
                () -> fixtures.service.commit(planId, workbook, "goods.xlsx"));

        assertTrue(error.getMessage().contains("发生了变化"));
    }

    @Test
    void commitRejectsAPlanDetectedByAnotherUser() throws Exception {
        Fixtures fixtures = fixtures();
        when(fixtures.currentUser.requireId()).thenReturn(
                UUID.randomUUID(), UUID.randomUUID());
        byte[] workbook = workbook("", "导入货品", "成品", "红色", "个");
        UUID planId = fixtures.service.detect(workbook).planId();

        ApiException error = assertThrows(
                ApiException.class,
                () -> fixtures.service.commit(planId, workbook, "goods.xlsx"));

        assertTrue(error.getMessage().contains("不属于当前用户"));
    }

    @Test
    void successfulCommitUsesTheExactUuidReferencesFrozenByDetect() throws Exception {
        GoodsRepository goods = mock(GoodsRepository.class);
        GoodsService goodsService = mock(GoodsService.class);
        MaterialCategoryRepository categories = mock(MaterialCategoryRepository.class);
        MaterialCategoryService categoryService = mock(MaterialCategoryService.class);
        ColorRepository colors = mock(ColorRepository.class);
        ColorService colorService = mock(ColorService.class);
        UnitRepository units = mock(UnitRepository.class);
        UnitService unitService = mock(UnitService.class);
        EntityManager em = writeEntityManager();
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        UUID categoryId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        when(categories.findByDeletedFalseOrderBySortOrderAscNameAsc())
                .thenReturn(List.of(category(categoryId, "成品")));
        when(colors.findAll()).thenReturn(List.of(color(colorId, "红色")));
        when(units.findAll()).thenReturn(List.of(unit(unitId, "个")));
        when(goodsService.saveImported(any())).thenReturn(UUID.randomUUID());
        GoodsImportService service = new GoodsImportService(
                goodsService, goods, categoryService, categories,
                colorService, colors, unitService, units, em, currentUser);
        byte[] workbook = workbook("", "导入货品", "成品", "红色", "个");
        UUID planId = service.detect(workbook).planId();

        service.commit(planId, workbook, "goods.xlsx");

        var request = org.mockito.ArgumentCaptor.forClass(GoodsSaveRequest.class);
        verify(goodsService).saveImported(request.capture());
        assertEquals(categoryId, request.getValue().getCategoryId());
        assertEquals(colorId, request.getValue().getColorId());
        assertEquals(unitId, request.getValue().getUnitId());
        assertNull(request.getValue().getColorLegacyId());
        assertNull(request.getValue().getUnitLegacyId());
        verify(categoryService, never()).create(any());
        verify(colorService, never()).create(any());
        verify(unitService, never()).create(any());
    }

    @Test
    void repeatedNewColorAndUnitTokensCreateOneMasterAndReuseItsUuid() throws Exception {
        GoodsRepository goods = mock(GoodsRepository.class);
        GoodsService goodsService = mock(GoodsService.class);
        MaterialCategoryRepository categories = mock(MaterialCategoryRepository.class);
        ColorRepository colors = mock(ColorRepository.class);
        ColorService colorService = mock(ColorService.class);
        UnitRepository units = mock(UnitRepository.class);
        UnitService unitService = mock(UnitService.class);
        UUID categoryId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        when(categories.findByDeletedFalseOrderBySortOrderAscNameAsc())
                .thenReturn(List.of(category(categoryId, "成品")));
        when(colors.findAll()).thenReturn(List.of());
        when(units.findAll()).thenReturn(List.of());
        when(colorService.create(any())).thenReturn(
                new ColorDetail(colorId, "C1", "新红", "使用", null));
        when(unitService.create(any())).thenReturn(
                new UnitDetail(unitId, "U1", "箱", "使用", null, null));
        when(goodsService.saveImported(any())).thenReturn(UUID.randomUUID());
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        GoodsImportService service = new GoodsImportService(
                goodsService, goods, mock(MaterialCategoryService.class), categories,
                colorService, colors, unitService, units, writeEntityManager(), currentUser);
        byte[] workbook = workbookWithDuplicateMasters();
        UUID planId = service.detect(workbook).planId();

        service.commit(planId, workbook, "goods.xlsx");

        verify(colorService).create(any());
        verify(unitService).create(any());
        var requests = org.mockito.ArgumentCaptor.forClass(GoodsSaveRequest.class);
        verify(goodsService, org.mockito.Mockito.times(2)).saveImported(requests.capture());
        assertTrue(requests.getAllValues().stream().allMatch(
                request -> colorId.equals(request.getColorId())
                        && unitId.equals(request.getUnitId())
                        && request.getColorLegacyId() == null
                        && request.getUnitLegacyId() == null));
    }

    private static Fixtures fixtures() {
        GoodsRepository goods = mock(GoodsRepository.class);
        MaterialCategoryRepository categories = mock(MaterialCategoryRepository.class);
        ColorRepository colors = mock(ColorRepository.class);
        UnitRepository units = mock(UnitRepository.class);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);

        UUID categoryId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        when(categories.findByDeletedFalseOrderBySortOrderAscNameAsc())
                .thenReturn(List.of(category(categoryId, "成品")));
        when(colors.findAll()).thenReturn(List.of(color(colorId, "红色")));
        when(units.findAll()).thenReturn(List.of(unit(unitId, "个")));
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());

        GoodsImportService service = new GoodsImportService(
                null, goods, null, categories,
                null, colors, null, units, null, currentUser);
        return new Fixtures(service, colors, units, currentUser, unitId);
    }

    private static EntityManager writeEntityManager() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.executeUpdate()).thenReturn(1);
        return em;
    }

    private static MaterialCategory category(UUID id, String name) {
        MaterialCategory value = new MaterialCategory();
        value.setId(id);
        value.setName(name);
        return value;
    }

    private static Color color(UUID id, String name) {
        Color value = new Color();
        value.setId(id);
        value.setName(name);
        return value;
    }

    private static Unit unit(UUID id, String name) {
        Unit value = new Unit();
        value.setId(id);
        value.setName(name);
        return value;
    }

    private static byte[] workbook(
            String code,
            String name,
            String category,
            String color,
            String unit) throws Exception {
        try (XSSFWorkbook workbook = new XSSFWorkbook();
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            var sheet = workbook.createSheet("货品");
            var header = sheet.createRow(0);
            header.createCell(0).setCellValue("编号");
            header.createCell(1).setCellValue("名称");
            header.createCell(2).setCellValue("类别");
            header.createCell(3).setCellValue("主颜色");
            header.createCell(4).setCellValue("单位");
            var row = sheet.createRow(1);
            row.createCell(0).setCellValue(code);
            row.createCell(1).setCellValue(name);
            row.createCell(2).setCellValue(category);
            row.createCell(3).setCellValue(color);
            row.createCell(4).setCellValue(unit);
            workbook.write(output);
            return output.toByteArray();
        }
    }

    private static byte[] workbookWithDuplicateMasters() throws Exception {
        try (XSSFWorkbook workbook = new XSSFWorkbook();
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            var sheet = workbook.createSheet("货品");
            var header = sheet.createRow(0);
            header.createCell(0).setCellValue("编号");
            header.createCell(1).setCellValue("名称");
            header.createCell(2).setCellValue("类别");
            header.createCell(3).setCellValue("主颜色");
            header.createCell(4).setCellValue("单位");
            for (int i = 1; i <= 2; i++) {
                var row = sheet.createRow(i);
                row.createCell(0).setCellValue("");
                row.createCell(1).setCellValue("导入货品" + i);
                row.createCell(2).setCellValue("成品");
                row.createCell(3).setCellValue("新红");
                row.createCell(4).setCellValue("箱");
            }
            workbook.write(output);
            return output.toByteArray();
        }
    }

    private record Fixtures(
            GoodsImportService service,
            ColorRepository colors,
            UnitRepository units,
            SecurityContextCurrentUser currentUser,
            UUID unitId) {}
}
