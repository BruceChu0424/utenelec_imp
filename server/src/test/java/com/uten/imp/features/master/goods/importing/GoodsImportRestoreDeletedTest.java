package com.uten.imp.features.master.goods.importing;

import com.uten.imp.support.GoodsImportIdentifierAvailabilityFixture;

import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.GoodsRepository;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 恢复契约（2026-10-28 收口为只认系统标识）：文件携带指向已软删货品的系统标识时，
 * detect 规划为恢复而不是冲突，commit 走 [GoodsService.restoreImported]（同 UUID 原编号
 * 复活），不再新建身份。编号本身不再触发匹配：无系统标识一律按新建处理，编号占用
 * 在用货品即整行报「编号重复」。
 */
class GoodsImportRestoreDeletedTest {
    @org.junit.jupiter.api.AfterEach void clearAuthentication() {
        org.springframework.security.core.context.SecurityContextHolder.clearContext();
    }

    @Test
    void detect_plansRestoreWhenTheWorkbookCarriesTheDeletedGoodsUuid() throws Exception {
        GoodsRepository goods = mock(GoodsRepository.class);
        UUID deletedId = UUID.randomUUID();
        var deleted = deletedGoods(deletedId, "208035801");
        when(goods.findById(deletedId)).thenReturn(Optional.of(deleted));
        GoodsImportService service = service(goods, null);

        GoodsImportReport report = service.detect(workbook("208035801", "恢复货品", "成品", deletedId.toString()));

        assertTrue(report.errors().isEmpty(), () -> report.errors().toString());
        assertEquals(1, report.readyToImport());
        assertEquals(1, report.restorableRows());
        assertTrue(report.planId() != null);
    }

    @Test
    void detect_treatsASoftDeletedCodeWithoutUuidAsANewRecord() throws Exception {
        GoodsRepository goods = mock(GoodsRepository.class);
        when(goods.existsByCodeAndDeletedFalse("208035801")).thenReturn(false);
        when(goods.codeHasReuseHistory("208035801")).thenReturn(false);
        GoodsImportService service = service(goods, null);

        GoodsImportReport report = service.detect(workbook("208035801", "新建货品", "成品", null));

        assertTrue(report.errors().isEmpty(), () -> report.errors().toString());
        assertEquals(1, report.addedRows());
        assertEquals(0, report.restorableRows());
    }

    @Test
    void detect_reportsDuplicateCodeWhenNoUuidAndCodeBelongsToALiveGoods() throws Exception {
        GoodsRepository goods = mock(GoodsRepository.class);
        when(goods.existsByCodeAndDeletedFalse("208035801")).thenReturn(true);
        GoodsImportService service = service(goods, null);

        GoodsImportReport report = service.detect(workbook("208035801", "冲突货品", "成品", null));

        assertEquals(1, report.errors().size());
        assertEquals("编号", report.errors().getFirst().column());
        assertTrue(report.errors().getFirst().message().contains("编号重复"));
        assertEquals(0, report.restorableRows());
    }

    @Test
    void detect_rejectsAUuidWhoseCodeDisagreesWithTheDeletedGoods() throws Exception {
        GoodsRepository goods = mock(GoodsRepository.class);
        UUID deletedId = UUID.randomUUID();
        when(goods.findById(deletedId)).thenReturn(Optional.of(deletedGoods(deletedId, "208035801")));
        GoodsImportService service = service(goods, null);

        GoodsImportReport report = service.detect(workbook("999999999", "恢复货品", "成品", deletedId.toString()));

        assertEquals(1, report.errors().size());
        assertEquals("系统标识", report.errors().getFirst().column());
        assertEquals(0, report.restorableRows());
    }

    @Test
    void commit_restoresTheSoftDeletedIdentityInsteadOfCreatingANewOne() throws Exception {
        org.springframework.security.core.context.SecurityContextHolder.getContext().setAuthentication(
                new org.springframework.security.authentication.UsernamePasswordAuthenticationToken("restore-importer","unused",
                        java.util.List.of(new org.springframework.security.core.authority.SimpleGrantedAuthority("goods:edit"))));
        GoodsRepository goods = mock(GoodsRepository.class);
        GoodsService goodsService = mock(GoodsService.class);
        UUID deletedId = UUID.randomUUID();
        var deleted = deletedGoods(deletedId, "208035801");
        deleted.setName("恢复货品");
        when(goods.findById(deletedId)).thenReturn(Optional.of(deleted));
        when(goodsService.restoreImported(any(UUID.class), any())).thenReturn(deletedId);
        GoodsImportService service = service(goods, goodsService);

        byte[] xlsx = workbook("208035801", "恢复货品", "成品", deletedId.toString());
        GoodsImportReport report = service.detect(xlsx);
        service.commit(report.planId(), xlsx, "恢复清单.xlsx");

        verify(goodsService).restoreImported(any(UUID.class), any());
        verify(goodsService, never()).saveImported(any());
    }

    private static com.uten.imp.features.master.goods.Goods deletedGoods(UUID id, String code) {
        var deleted = new com.uten.imp.features.master.goods.Goods();
        deleted.setId(id);
        deleted.setCode(code);
        deleted.setDeleted(true);
        return deleted;
    }

    private static GoodsImportService service(GoodsRepository goods, GoodsService goodsService) {
        MaterialCategoryRepository categories = mock(MaterialCategoryRepository.class);
        var existingCategory = new com.uten.imp.features.master.materialcategory.MaterialCategory();
        existingCategory.setName("成品");
        existingCategory.setCode("RESTORE-CAT");
        when(categories.findByDeletedFalseOrderBySortOrderAscNameAsc())
                .thenReturn(List.of(existingCategory));
        ColorRepository colors = mock(ColorRepository.class);
        when(colors.findAll()).thenReturn(List.of());
        UnitRepository units = mock(UnitRepository.class);
        when(units.findAll()).thenReturn(List.of());
        jakarta.persistence.EntityManager em = mock(jakarta.persistence.EntityManager.class);
        var nativeQuery = mock(jakarta.persistence.Query.class);
        when(nativeQuery.setParameter(anyString(), any())).thenReturn(nativeQuery);
        when(em.createNativeQuery(anyString())).thenReturn(nativeQuery);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        return GoodsImportIdentifierAvailabilityFixture.allowAll(new GoodsImportService(
                goodsService == null ? mock(GoodsService.class) : goodsService, goods, null, categories,
                null, colors, null, units, em, currentUser, null));
    }

    private static byte[] workbook(String code, String name, String category, String goodsId) throws Exception {
        try (XSSFWorkbook workbook = new XSSFWorkbook();
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            var sheet = workbook.createSheet("货品");
            var header = sheet.createRow(0);
            header.createCell(0).setCellValue("编号");
            header.createCell(1).setCellValue("名称");
            header.createCell(2).setCellValue("类别");
            header.createCell(3).setCellValue("系统标识");
            var row = sheet.createRow(1);
            row.createCell(0).setCellValue(code);
            row.createCell(1).setCellValue(name);
            row.createCell(2).setCellValue(category);
            if (goodsId != null) row.createCell(3).setCellValue(goodsId);
            workbook.write(output);
            return output.toByteArray();
        }
    }
}
