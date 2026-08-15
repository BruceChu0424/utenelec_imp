package com.uten.imp.features.master.goods.importing;

import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.GoodsRepository;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class GoodsImportOptionalCodeTest {

    @Test
    void detect_allowsBlankCodeForCategoryDrivenAllocation() throws Exception {
        GoodsRepository goods = mock(GoodsRepository.class);
        GoodsImportService service = service(goods);

        GoodsImportReport report = service.detect(workbook("", "导入货品", "成品-V6"));

        assertTrue(report.errors().isEmpty());
        assertEquals(1, report.readyToImport());
        verify(goods, never()).existsByCodeAndDeletedFalse(org.mockito.ArgumentMatchers.anyString());
    }

    @Test
    void detect_stillRejectsAnExplicitCodeAlreadyInUse() throws Exception {
        GoodsRepository goods = mock(GoodsRepository.class);
        when(goods.existsByCodeAndDeletedFalse("V6000001")).thenReturn(true);
        GoodsImportService service = service(goods);

        GoodsImportReport report = service.detect(workbook("v6000001", "导入货品", "成品-V6"));

        assertEquals(1, report.errors().size());
        assertEquals("编号", report.errors().get(0).column());
        assertTrue(report.errors().get(0).message().contains("已存在"));
    }

    private static GoodsImportService service(GoodsRepository goods) {
        MaterialCategoryRepository categories = mock(MaterialCategoryRepository.class);
        when(categories.findByDeletedFalseOrderBySortOrderAscNameAsc()).thenReturn(List.of());
        ColorRepository colors = mock(ColorRepository.class);
        when(colors.findAll()).thenReturn(List.of());
        UnitRepository units = mock(UnitRepository.class);
        when(units.findAll()).thenReturn(List.of());
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(java.util.UUID.randomUUID());
        return new GoodsImportService(
                null, goods, null, categories,
                null, colors, null, units, null, currentUser);
    }

    private static byte[] workbook(String code, String name, String category) throws Exception {
        try (XSSFWorkbook workbook = new XSSFWorkbook();
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            var sheet = workbook.createSheet("货品");
            var header = sheet.createRow(0);
            header.createCell(0).setCellValue("编号");
            header.createCell(1).setCellValue("名称");
            header.createCell(2).setCellValue("类别");
            var row = sheet.createRow(1);
            row.createCell(0).setCellValue(code);
            row.createCell(1).setCellValue(name);
            row.createCell(2).setCellValue(category);
            workbook.write(output);
            return output.toByteArray();
        }
    }
}
