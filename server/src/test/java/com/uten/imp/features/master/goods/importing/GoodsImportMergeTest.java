package com.uten.imp.features.master.goods.importing;

import com.uten.imp.support.GoodsImportIdentifierAvailabilityFixture;

import com.uten.imp.application.port.GoodsMasterWriteAccessPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.Goods;
import com.uten.imp.features.master.goods.GoodsRepository;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.ReflectionTestUtils;

import java.io.ByteArrayOutputStream;
import java.math.BigDecimal;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class GoodsImportMergeTest {
    @AfterEach void clearSecurity() { SecurityContextHolder.clearContext(); }

    @Test void detectsFillAndConflictCellsWithoutWriting() throws Exception {
        Fixture f = fixture();
        f.goods.setCNumber("111");
        byte[] file = workbook("G1", "现有货品", "222", "新的客户品名", "", f.goods.getId().toString());

        GoodsImportReport report = f.service.detect(file);

        assertTrue(report.errors().isEmpty());
        assertEquals(1, report.fillRows());
        assertEquals(1, report.conflictRows());
        assertEquals(0, report.addedRows());
        var changes = report.reviewRows().getFirst().changes();
        assertEquals("111", changes.stream().filter(c -> c.field().equals("cNumber")).findFirst().orElseThrow().oldValue());
        assertEquals("CONFLICT", changes.stream().filter(c -> c.field().equals("cNumber")).findFirst().orElseThrow().kind());
        assertEquals("FILL", changes.stream().filter(c -> c.field().equals("clientGoodsName")).findFirst().orElseThrow().kind());
        verifyNoInteractions(f.goodsService);
    }

    @Test void ignoringConflictStillFillsEmptyCellsAndPreservesEveryOtherScalar() throws Exception {
        Fixture f = fixture();
        f.goods.setCNumber("111");
        f.goods.setSpec("原规格");
        f.goods.setMaterial("不锈钢");
        f.goods.setPaper("历史备注");
        f.goods.setShortName("历史简称");
        f.goods.setThickness(new BigDecimal("3.5000"));
        f.goods.setMWeight(new BigDecimal("2.0000"));
        f.goods.setSourceE(new BigDecimal("12.3400"));
        f.goods.setMinOrderQty(new BigDecimal("50.0000"));
        f.goods.setNameEn("Existing name");
        f.goods.setClientGoodsName(null);
        byte[] file = workbook("G1", "现有货品", "222", "新客户品名", "", f.goods.getId().toString());
        var report = f.service.detect(file);

        var result = f.service.commit(report.planId(), file, "goods.xlsx", Set.of());

        GoodsSaveRequest request = captured(f);
        assertFalse(request.hasCNumber());
        assertEquals("新客户品名", request.getClientGoodsName());
        assertEquals("原规格", request.getSpec());
        assertEquals("不锈钢", request.getMaterial());
        assertEquals("历史备注", request.getPaper());
        assertEquals("历史简称", request.getShortName());
        assertEquals(new BigDecimal("3.5000"), request.getThickness());
        assertEquals(new BigDecimal("2.0000"), request.getMWeight());
        assertEquals(new BigDecimal("12.3400"), request.getSourceE());
        assertEquals(new BigDecimal("50.0000"), request.getMinOrderQty());
        assertFalse(request.hasNameEn());
        assertEquals(8L, request.getVersion());
        assertFalse(request.hasUnitReference());
        assertFalse(request.hasColorReference());
        assertEquals(0, result.updatedCount());
        assertEquals(1, result.filledCount());
        assertEquals(1, result.ignoredCount());
        assertEquals(1, result.importedCount());
    }

    @Test void selectedConflictReplacesOnlyNonblankImportedCells() throws Exception {
        Fixture f = fixture();
        f.goods.setCNumber("111");
        f.goods.setSpec("原规格");
        byte[] file = workbook("G1", "现有货品", "222", "", "", f.goods.getId().toString());
        var report = f.service.detect(file);

        var result = f.service.commit(report.planId(), file, "goods.xlsx", Set.of("goods:2"));

        assertEquals("222", captured(f).getCNumber());
        assertEquals("原规格", capturedAgain(f).getSpec());
        assertEquals(1, result.updatedCount());
        assertEquals(0, result.ignoredCount());
    }

    @Test void reviewedCategoryCellCorrectionMovesExistingGoodsToTheResolvedCategory() throws Exception {
        Fixture f = fixture();
        var target = category("转入分类");
        var categories = (MaterialCategoryRepository) ReflectionTestUtils.getField(f.service, "categoryRepo");
        when(categories.findByDeletedFalseOrderBySortOrderAscNameAsc()).thenReturn(List.of(f.category, target));
        byte[] file = workbook("G1", "现有货品", "", "", "", f.goods.getId().toString());
        Map<Integer, Map<String, String>> cells = Map.of(2, Map.of("categoryPath", "转入分类"));

        var report = f.service.detect(file, Map.of(), Set.of(), cells, GoodsImportMode.UPDATE_ONLY);

        assertTrue(report.errors().isEmpty(), report.errors().toString());
        assertEquals("转入分类", report.previewRows().getFirst().categoryPath());
        assertTrue(report.reviewRows().getFirst().changes().stream().anyMatch(change ->
                change.field().equals("categoryId") && change.newValue().equals("转入分类")));
        f.service.commit(report.planId(), file, "move.xlsx", Set.of("goods:2"), Map.of(), Set.of(), cells,
                GoodsImportMode.UPDATE_ONLY);

        assertEquals(target.getId(), captured(f).getCategoryId());
        verify(f.goodsService, never()).saveImported(any());
    }

    @Test void reviewedNewCategoryCellCreatesOnlyTheMissingDescendantAndMovesTheSameGoodsIdentity() throws Exception {
        Fixture f = fixture();
        var categoryService = mock(com.uten.imp.features.master.materialcategory.MaterialCategoryService.class);
        var detail = mock(com.uten.imp.features.master.materialcategory.dto.MaterialCategoryDetail.class);
        UUID childId = UUID.randomUUID();
        when(detail.getId()).thenReturn(childId);
        when(categoryService.create(any())).thenReturn(detail);
        ReflectionTestUtils.setField(f.service, "categoryService", categoryService);
        byte[] file = workbook("G1", "现有货品", "", "", "", f.goods.getId().toString());
        Map<Integer, Map<String, String>> cells = Map.of(2, Map.of("categoryPath", "成品 / 确认新分类"));

        var report = f.service.detect(file, Map.of(), Set.of(), cells, GoodsImportMode.UPDATE_ONLY);
        assertTrue(report.errors().isEmpty(), report.errors().toString());
        assertEquals(List.of("成品/确认新分类"), report.willCreateCategories());
        var result = f.service.commit(report.planId(), file, "new-category.xlsx", Set.of("goods:2"),
                Map.of(), Set.of(), cells, GoodsImportMode.UPDATE_ONLY);

        var categoryRequest = org.mockito.ArgumentCaptor.forClass(
                com.uten.imp.features.master.materialcategory.dto.MaterialCategorySaveRequest.class);
        verify(categoryService).create(categoryRequest.capture());
        assertEquals("确认新分类", categoryRequest.getValue().getName());
        assertEquals(f.category.getId(), categoryRequest.getValue().getParentId());
        assertEquals(childId, captured(f).getCategoryId());
        assertEquals(1, result.createdCategories());
        verify(f.goodsService, never()).saveImported(any());
    }

    @Test void blankCellsAndEqualCellsNeverProduceAnUpdateOrUndoBatch() throws Exception {
        Fixture f = fixture();
        f.goods.setCNumber("111");
        f.goods.setSpec("原规格");
        byte[] file = workbook("G1", "现有货品", "", "", "原规格", f.goods.getId().toString());
        var report = f.service.detect(file);

        assertEquals(0, report.readyToImport());
        assertEquals(1, report.unchangedRows());
        assertTrue(report.reviewRows().isEmpty());
        var result = f.service.commit(report.planId(), file, "goods.xlsx");
        assertNull(result.batchId());
        assertEquals(1, result.unchangedCount());
        verifyNoInteractions(f.goodsService);
    }

    @Test void ignoringOnlyConflictsDoesNotRegisterAnEmptyUndoBatch() throws Exception {
        Fixture f = fixture();
        f.goods.setCNumber("111");
        byte[] file = workbook("G1", "现有货品", "222", "", "", f.goods.getId().toString());
        var report = f.service.detect(file);
        var result = f.service.commit(report.planId(), file, "goods.xlsx");
        assertNull(result.batchId());
        assertEquals(1, result.ignoredCount());
        assertEquals(0, result.importedCount());
        verifyNoInteractions(f.goodsService);
    }

    @Test void samePathAndNameWithoutIdentifiersCreatesANewVariant() throws Exception {
        Fixture f = fixture();
        byte[] file = workbook("", "现有货品", "222", "", "");
        var report = f.service.detect(file);
        assertTrue(report.errors().isEmpty());
        assertTrue(report.reviewRows().isEmpty());
        assertEquals(1, report.addedRows());
        f.service.commit(report.planId(), file, "goods.xlsx");
        verify(f.goodsService).saveImported(any());
        verify(f.goodsService, never()).updateImported(any(), any());
    }

    @Test void existingSameNameVariantsDoNotBlockANewAutomaticCode() throws Exception {
        Fixture f = fixture();
        Goods duplicate = goods(f.category, "G2", "现有货品");
        when(f.repo.findImportIdentities()).thenReturn(List.of(identity(f.goods), identity(duplicate)));
        var report = f.service.detect(workbook("", "现有货品", "222", "", ""));
        assertNotNull(report.planId());
        assertTrue(report.errors().isEmpty());
        assertEquals(1, report.addedRows());
        assertTrue(report.reviewRows().isEmpty());
    }

    @Test void samePathAndNameWithAnUnusedExplicitCodeCreatesANewVariant() throws Exception {
        Fixture f = fixture();
        byte[] file = workbook("NEW-CODE", "现有货品", "222", "新客户名称", "新规格");
        var report = f.service.detect(file);
        assertTrue(report.errors().isEmpty(), report.errors().toString());
        assertEquals(1, report.addedRows());
        assertTrue(report.reviewRows().isEmpty());

        var result = f.service.commit(report.planId(), file, "new-variant.xlsx");

        var request = org.mockito.ArgumentCaptor.forClass(GoodsSaveRequest.class);
        verify(f.goodsService).saveImported(request.capture());
        assertEquals("NEW-CODE", request.getValue().getCode());
        assertEquals("现有货品", request.getValue().getName());
        assertEquals("新规格", request.getValue().getSpec());
        assertEquals(1, result.createdCount());
        verify(f.goodsService, never()).updateImported(any(), any());
    }

    @Test void sameNameVariantsDoNotMakeAnExplicitNewCodeAmbiguous() throws Exception {
        Fixture f = fixture();
        Goods duplicate = goods(f.category, "G2", "现有货品");
        when(f.repo.findImportIdentities()).thenReturn(List.of(identity(f.goods), identity(duplicate)));
        var report = f.service.detect(workbook("NEW-CODE", "现有货品", "222", "", ""));
        assertTrue(report.errors().isEmpty(), report.errors().toString());
        assertEquals(1, report.addedRows());
    }

    @Test void newSameNameVariantPreservesItsOwnMaterialAndColor() throws Exception {
        Fixture f = fixture();
        f.goods.setMaterial("铜");
        var color = new com.uten.imp.features.master.color.Color();
        color.setId(UUID.randomUUID()); color.setName("白色"); color.setStatus("使用");
        var colors = (ColorRepository) ReflectionTestUtils.getField(f.service, "colorRepo");
        when(colors.findAll()).thenReturn(List.of(color));
        try (var book = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            var sheet = book.createSheet("货品"); var header = sheet.createRow(0); var row = sheet.createRow(1);
            String[] titles = {"编号", "名称", "类别", "材质", "主颜色"};
            String[] values = {"NEW-CODE", "现有货品", "成品", "铝", "白色"};
            for (int n = 0; n < titles.length; n++) { header.createCell(n).setCellValue(titles[n]); row.createCell(n).setCellValue(values[n]); }
            book.write(out); byte[] file = out.toByteArray();
            var report = f.service.detect(file);
            assertTrue(report.errors().isEmpty(), report.errors().toString());
            f.service.commit(report.planId(), file, "material-color-variant.xlsx");

            var request = org.mockito.ArgumentCaptor.forClass(GoodsSaveRequest.class);
            verify(f.goodsService).saveImported(request.capture());
            assertEquals("铝", request.getValue().getMaterial());
            assertEquals(color.getId(), request.getValue().getColorId());
            assertEquals("铜", f.goods.getMaterial());
            verify(f.goodsService, never()).updateImported(any(), any());
        }
    }

    @Test void anExportedUuidWithBlankCodeKeepsItsIdentityAndExistingCode() throws Exception {
        Fixture f = fixture();
        Goods duplicate = goods(f.category, "G2", "现有货品");
        when(f.repo.findImportIdentities()).thenReturn(List.of(identity(f.goods), identity(duplicate)));
        byte[] file = workbookWithUuid("", f.goods.getId().toString());
        var report = f.service.detect(file);

        assertTrue(report.errors().isEmpty(), report.errors().toString());
        assertEquals(1, report.unchangedRows());
        assertEquals(0, report.addedRows());
        f.service.commit(report.planId(), file, "blank-code-roundtrip.xlsx");
        verifyNoInteractions(f.goodsService);
    }

    @Test void removingTheNumberColumnKeepsTheLocalUuidAndFillsOnlyProvidedValues() throws Exception {
        Fixture f = fixture();
        byte[] file = workbookWithoutCode(f.goods.getId().toString(), "新客户品名");
        var report = f.service.detect(file);

        assertTrue(report.errors().isEmpty(), report.errors().toString());
        assertEquals(0, report.addedRows());
        assertEquals("UUID", report.reviewRows().getFirst().matchType());
        var result = f.service.commit(report.planId(), file, "without-code.xlsx");

        assertEquals("G1", captured(f).getCode());
        assertEquals("新客户品名", capturedAgain(f).getClientGoodsName());
        assertEquals(1, result.filledCount());
        verify(f.goodsService, never()).saveImported(any());
    }

    @Test void unknownExportUuidsWithNoNumberEachCreateANewLocalIdentity() throws Exception {
        for (String incomingCode : Arrays.asList(null, "", "NEW-CODE")) {
            Fixture f = fixture();
            String foreignId = UUID.randomUUID().toString();
            byte[] file = incomingCode == null ? workbookWithoutCode(foreignId, "")
                    : workbookWithUuid(incomingCode, foreignId);
            var report = f.service.detect(file);

            assertTrue(report.errors().isEmpty(), report.errors().toString());
            assertEquals(1, report.addedRows());
            assertTrue(report.reviewRows().isEmpty());
            var result = f.service.commit(report.planId(), file, "historical-export.xlsx");

            var request = org.mockito.ArgumentCaptor.forClass(GoodsSaveRequest.class);
            verify(f.goodsService).saveImported(request.capture());
            assertEquals(incomingCode, request.getValue().getCode());
            assertEquals(1, result.createdCount());
            verify(f.goodsService, never()).updateImported(any(), any());
        }
    }

    @Test void unknownExportUuidWithAClaimedCodeIsRejectedAsDuplicateCode() throws Exception {
        Fixture f = fixture();
        f.goods.setName("当前名称");
        var report = f.service.detect(workbookWithUuid("G1", UUID.randomUUID().toString()));

        assertNull(report.planId());
        assertTrue(report.reviewRows().isEmpty());
        assertTrue(report.errors().stream().anyMatch(error -> error.message().contains("编号重复")));
        verifyNoInteractions(f.goodsService);
    }

    @Test void unknownExportUuidCannotBypassCodeReuseOrDuplicateTargetGuards() throws Exception {
        Fixture f = fixture();
        when(f.repo.codeHasReuseHistory("G1")).thenReturn(true);
        var report = f.service.detect(workbookWithUuid("G1", UUID.randomUUID().toString()));
        assertNull(report.planId());
        assertTrue(report.errors().stream().anyMatch(error -> error.message().contains("曾复用")));

        f = fixture();
        try (var book = new XSSFWorkbook(new java.io.ByteArrayInputStream(
                workbookWithUuid("G1", UUID.randomUUID().toString())));
             var out = new ByteArrayOutputStream()) {
            var row = book.getSheetAt(0).createRow(2);
            String[] values = {"G1", "另一名称", "成品", UUID.randomUUID().toString()};
            for (int i = 0; i < values.length; i++) row.createCell(i).setCellValue(values[i]);
            book.write(out);
            report = f.service.detect(out.toByteArray());
            assertNull(report.planId());
            assertTrue(report.errors().stream().anyMatch(error -> error.message().contains("重复")));
            verifyNoInteractions(f.goodsService);
        }
    }

    @Test void anExportedUuidWithAnUnusedNewCodeRequiresReviewBeforeRenumbering() throws Exception {
        Fixture f = fixture();
        byte[] file = workbookWithUuid("NEW-CODE", f.goods.getId().toString());
        var report = f.service.detect(file);

        assertTrue(report.errors().isEmpty(), report.errors().toString());
        assertEquals(0, report.addedRows());
        assertEquals(1, report.conflictRows());
        var review = report.reviewRows().getFirst();
        assertEquals(f.goods.getId(), review.goodsId());
        assertEquals("UUID", review.matchType());
        assertEquals(List.of(new GoodsImportReviewRow.Change("code", "编号", "G1", "NEW-CODE", "CONFLICT")), review.changes());

        var result = f.service.commit(report.planId(), file, "rename.xlsx", Set.of("goods:2"));

        assertEquals("NEW-CODE", captured(f).getCode());
        assertEquals(1, result.updatedCount());
        verify(f.goodsService, never()).saveImported(any());
    }

    @Test void ignoringAnExportedCodeChangeDoesNotRenumberTheGoods() throws Exception {
        Fixture f = fixture();
        byte[] file = workbookWithUuid("NEW-CODE", f.goods.getId().toString());
        var report = f.service.detect(file);
        var result = f.service.commit(report.planId(), file, "ignore-rename.xlsx", Set.of());

        assertEquals(1, result.ignoredCount());
        assertEquals(0, result.importedCount());
        assertNull(result.batchId());
        verifyNoInteractions(f.goodsService);
    }

    @Test void blankCodeOrIgnoredNewCodeStillFillsOtherCellsWithoutRenumbering() throws Exception {
        for (String incomingCode : List.of("", "NEW-CODE")) {
            Fixture f = fixture();
            try (var book = new XSSFWorkbook(new java.io.ByteArrayInputStream(
                    workbook(incomingCode, "现有货品", "", "新客户品名", "")));
                 var out = new ByteArrayOutputStream()) {
                book.getSheetAt(0).getRow(0).createCell(6).setCellValue("系统标识");
                book.getSheetAt(0).getRow(1).createCell(6).setCellValue(f.goods.getId().toString());
                book.write(out); byte[] file = out.toByteArray();
                var report = f.service.detect(file);
                assertTrue(report.errors().isEmpty(), report.errors().toString());
                f.service.commit(report.planId(), file, "fill-without-renumbering.xlsx", Set.of());
                GoodsSaveRequest request = captured(f);
                assertEquals("G1", request.getCode());
                assertEquals("新客户品名", request.getClientGoodsName());
            }
        }
    }

    @Test void aCodeClaimedAfterRenameDetectionRejectsTheEntireCommit() throws Exception {
        Fixture f = fixture();
        byte[] file = workbookWithUuid("NEW-CODE", f.goods.getId().toString());
        var report = f.service.detect(file);
        Goods other = goods(f.category, "NEW-CODE", "其他货品");
        when(f.repo.findImportIdentities()).thenReturn(List.of(identity(f.goods), identity(other)));

        assertThrows(ApiException.class, () -> f.service.commit(report.planId(), file, "stale-rename.xlsx", Set.of("goods:2")));
        verifyNoInteractions(f.goodsService);
    }

    @Test void aReusedSourceCodeCanBeRenamedOnlyWhenItsUuidIsPreserved() throws Exception {
        Fixture f = fixture();
        when(f.repo.codeHasReuseHistory("G1")).thenReturn(true);
        byte[] file = workbookWithUuid("NEW-CODE", f.goods.getId().toString());
        var report = f.service.detect(file);
        assertTrue(report.errors().isEmpty(), report.errors().toString());
        f.service.commit(report.planId(), file, "rename-reused-code.xlsx", Set.of("goods:2"));
        assertEquals("NEW-CODE", captured(f).getCode());
    }

    @Test void aUuidCannotClaimAnotherDeletedGoodsCodeOrRestoreThatGoods() throws Exception {
        Fixture f = fixture();
        var deletedHolder = new Goods();
        deletedHolder.setId(UUID.randomUUID());
        when(f.repo.findFirstByCodeAndDeletedTrueOrderByIdAsc("DELETED-CODE")).thenReturn(Optional.of(deletedHolder));
        var report = f.service.detect(workbookWithUuid("DELETED-CODE", f.goods.getId().toString()));
        assertNull(report.planId());
        assertEquals(0, report.restorableRows());
        assertTrue(report.errors().stream().anyMatch(error -> error.message().contains("已删除货品编号不一致")));
        verifyNoInteractions(f.goodsService);
    }

    @Test void sameNameInAnotherCategoryAllowsAnAutomaticOrExplicitNewCode() throws Exception {
        Fixture f = fixture();
        f.goods.setCategory(category("另一分类"));
        var report = f.service.detect(workbook("", "现有货品", "222", "", ""));
        assertNotNull(report.planId());
        assertTrue(report.errors().isEmpty());
        assertEquals(1, report.addedRows());
        report = f.service.detect(workbook("NEW-CODE", "现有货品", "222", "", ""));
        assertTrue(report.errors().isEmpty(), report.errors().toString());
        assertEquals(1, report.addedRows());
        assertTrue(report.reviewRows().isEmpty());
    }

    @Test void detectedGoodsDriftRejectsTheEntireCommit() throws Exception {
        Fixture f = fixture();
        byte[] file = workbook("G1", "现有货品", "222", "", "", f.goods.getId().toString());
        var report = f.service.detect(file);
        f.goods.setCNumber("他人补齐");
        var error = assertThrows(ApiException.class, () -> f.service.commit(report.planId(), file, "goods.xlsx"));
        assertTrue(error.getMessage().contains("发生了变化"));
        verifyNoInteractions(f.goodsService);
    }

    @Test void aNewSamePathAndNameAfterDetectionRejectsTheCommit() throws Exception {
        Fixture f = fixture();
        byte[] file = workbook("", "全新货品", "222", "", "");
        var report = f.service.detect(file);
        when(f.repo.findImportIdentities()).thenReturn(List.of(identity(f.goods), identity(goods(f.category, "G2", "全新货品"))));
        assertThrows(ApiException.class, () -> f.service.commit(report.planId(), file, "goods.xlsx"));
        verifyNoInteractions(f.goodsService);
    }

    @Test void unsupportedReplacementSelectionIsRejectedBeforeWriting() throws Exception {
        Fixture f = fixture();
        byte[] file = workbook("G1", "现有货品", "222", "", "", f.goods.getId().toString());
        var report = f.service.detect(file);
        assertThrows(ApiException.class, () -> f.service.commit(report.planId(), file, "goods.xlsx", Set.of("goods:999")));
        verifyNoInteractions(f.goodsService);
    }

    @Test void importPermissionAloneDoesNotAllowEditingExistingGoods() throws Exception {
        Fixture f = fixture();
        authorities("goods:import");
        byte[] file = workbook("G1", "现有货品", "222", "", "", f.goods.getId().toString());
        var report = f.service.detect(file);
        assertNull(report.planId());
        assertEquals(List.of(2), report.problemRows().stream().map(GoodsImportProblemRow::rowNum).toList());
        assertTrue(report.reviewRows().isEmpty());
        assertThrows(ApiException.class, () -> f.service.commit(report.planId(), file, "goods.xlsx"));
        verifyNoInteractions(f.goodsService);
    }

    @Test void objectWriteScopeIsCheckedBeforeExposingStoredValues() throws Exception {
        Fixture f = fixture();
        doThrow(new ApiException(com.uten.imp.common.web.ErrorCode.NOT_FOUND, "货品不存在"))
                .when(f.access).requireWritable(f.goods.getId());
        var report = f.service.detect(workbook("G1", "现有货品", "222", "", "", f.goods.getId().toString()));
        assertNull(report.planId());
        assertEquals(List.of(2), report.problemRows().stream().map(GoodsImportProblemRow::rowNum).toList());
        assertTrue(report.reviewRows().isEmpty());
        assertTrue(report.errors().stream().anyMatch(error -> error.message().contains("权限")));
    }

    @Test void uuidAndCodeMustReferToTheSameIdentity() throws Exception {
        Fixture f = fixture();
        Goods other = goods(f.category, "G2", "其他货品");
        when(f.repo.findById(other.getId())).thenReturn(Optional.of(other));
        byte[] file = workbookWithUuid(other.getId().toString());
        var report = f.service.detect(file);
        assertNull(report.planId());
        assertTrue(report.errors().stream().anyMatch(error -> error.message().contains("不同货品")));
    }

    @Test void sameNameRowsWithDifferentCustomerModelsAllocateSeparateIdentities() throws Exception {
        Fixture f = fixture();
        try (var book = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            var sheet = book.createSheet("货品");
            var header = sheet.createRow(0);
            String[] titles = {"编号", "名称", "类别", "客户型号"};
            for (int i = 0; i < titles.length; i++) header.createCell(i).setCellValue(titles[i]);
            for (int n = 1; n <= 2; n++) {
                var row = sheet.createRow(n);
                row.createCell(1).setCellValue("新货品");
                row.createCell(2).setCellValue("新分类-新子类");
                row.createCell(3).setCellValue(n == 1 ? "111" : "222");
            }
            book.write(out);
            var report = f.service.detect(out.toByteArray());
            assertNotNull(report.planId());
            assertTrue(report.errors().isEmpty(), report.errors().toString());
            assertEquals(2, report.addedRows());
            verifyNoInteractions(f.goodsService);
        }
    }

    @Test void reviewPlansAllowThirtyMinutesAndEvictTheOldestAfterThirtyTwoPlans() throws Exception {
        Fixture f = fixture();
        byte[] file = workbook("G1", "现有货品", "222", "", "", f.goods.getId().toString());
        var first = f.service.detect(file);
        @SuppressWarnings("unchecked")
        var plans = (java.util.Map<UUID, ?>) ReflectionTestUtils.getField(f.service, "plans");
        assertNotNull(plans);
        Object plan = plans.get(first.planId());
        var expiry = plan.getClass().getDeclaredMethod("expiresAt"); expiry.setAccessible(true);
        long minutes = java.time.Duration.between(java.time.Instant.now(), (java.time.Instant) expiry.invoke(plan)).toMinutes();
        assertTrue(minutes >= 29 && minutes <= 30);
        for (int n = 0; n < 32; n++) f.service.detect(file);
        assertEquals(32, plans.size());
        var error = assertThrows(ApiException.class, () -> f.service.commit(first.planId(), file, "goods.xlsx"));
        assertTrue(error.getMessage().contains("已释放"));
    }

    @Test void oversizedReviewStateIsRejectedInsteadOfExceedingTheSharedCacheBudget() throws Exception {
        Fixture f = fixture();
        // Exercise the memory budget without relying on the database's shorter
        // field limit: even corrupt/legacy oversized values cannot fill the cache.
        f.goods.setSpec("X".repeat(17 * 1024 * 1024));
        var error = assertThrows(ApiException.class, () -> f.service.detect(workbook("G1", "现有货品", "222", "", "small", f.goods.getId().toString())));
        assertEquals(com.uten.imp.common.web.ErrorCode.PAYLOAD_TOO_LARGE, error.getCode());
        @SuppressWarnings("unchecked")
        var plans = (java.util.Map<UUID, ?>) ReflectionTestUtils.getField(f.service, "plans");
        assertTrue(plans.isEmpty());
    }

    @Test void exportedNumericDisplayFormatsDoNotRoundPriceOrOrderPolicyDuringImport() throws Exception {
        Fixture f = fixture();
        var current = (SecurityContextCurrentUser) ReflectionTestUtils.getField(f.service, "currentUser");
        when(current.get()).thenReturn(Optional.of(new com.uten.imp.security.AuthUser(UUID.randomUUID(), UUID.randomUUID(),
                "price-test", Set.of("goods:price:view"), false, true, false)));
        f.goods.setPrice(new BigDecimal("1.2345"));
        f.goods.setMinOrderQty(new BigDecimal("0.0001"));
        f.goods.setOrderMultipleQty(new BigDecimal("2.3456"));
        try (var book = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            var sheet = book.createSheet("货品"); var header = sheet.createRow(0);
            String[] titles = {"编号", "名称", "类别", "客户型号", "价格", "最小起订量", "订货倍数", "系统标识"};
            for (int n = 0; n < titles.length; n++) header.createCell(n).setCellValue(titles[n]);
            var row = sheet.createRow(1);
            row.createCell(0).setCellValue("G1"); row.createCell(1).setCellValue("现有货品");
            row.createCell(2).setCellValue("成品"); row.createCell(3).setCellValue("222");
            row.createCell(7).setCellValue(f.goods.getId().toString());
            var style = book.createCellStyle(); style.setDataFormat(book.createDataFormat().getFormat("0.00"));
            double[] numbers = {1.2345, 0.0001, 2.3456};
            for (int n = 0; n < numbers.length; n++) { var cell = row.createCell(n + 4); cell.setCellValue(numbers[n]); cell.setCellStyle(style); }
            book.write(out);
            var report = f.service.detect(out.toByteArray());
            assertTrue(report.errors().isEmpty(), report.errors().toString());
            assertEquals(List.of("cNumber"), report.reviewRows().getFirst().changes().stream().map(GoodsImportReviewRow.Change::field).toList());
        }
    }

    @Test void unchangedExportedLegacyUnitAndColorNamesDoNotCreateUuidRelationships() throws Exception {
        Fixture f = fixture();
        var unit = new com.uten.imp.features.master.unit.Unit(); unit.setLegacyId(101); unit.setName("个"); unit.setStatus("使用");
        var color = new com.uten.imp.features.master.color.Color(); color.setLegacyId(102); color.setName("红色"); color.setStatus("使用");
        var unitRepo = (UnitRepository) ReflectionTestUtils.getField(f.service, "unitRepo");
        var colorRepo = (ColorRepository) ReflectionTestUtils.getField(f.service, "colorRepo");
        when(unitRepo.findAll()).thenReturn(List.of(unit)); when(colorRepo.findAll()).thenReturn(List.of(color));
        f.goods.setUnitLegacyId(101); f.goods.setColorLegacyId(102);
        when(f.repo.quantityUnitInUse(f.goods.getId())).thenReturn(true);
        try (var book = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            var sheet = book.createSheet("货品"); var header = sheet.createRow(0);
            String[] titles = {"编号", "名称", "类别", "客户型号", "单位", "主颜色", "系统标识"};
            String[] values = {"G1", "现有货品", "成品", "222", "个", "红色", f.goods.getId().toString()};
            var row = sheet.createRow(1);
            for (int n = 0; n < titles.length; n++) { header.createCell(n).setCellValue(titles[n]); row.createCell(n).setCellValue(values[n]); }
            book.write(out); byte[] file = out.toByteArray(); var report = f.service.detect(file);
            assertTrue(report.errors().isEmpty(), report.errors().toString());
            assertEquals(List.of("cNumber"), report.reviewRows().getFirst().changes().stream().map(GoodsImportReviewRow.Change::field).toList());
            f.service.commit(report.planId(), file, "legacy-roundtrip.xlsx");
            GoodsSaveRequest request = captured(f);
            assertFalse(request.hasUnitReference()); assertFalse(request.hasColorReference());
        }
    }

    @Test void aReusedDisplayCodeCannotMatchOrFillGoodsWithoutItsSystemUuid() throws Exception {
        Fixture f = fixture();
        when(f.repo.codeHasReuseHistory("G1")).thenReturn(true);
        var report = f.service.detect(workbook("G1", "现有货品", "222", "", ""));
        assertNull(report.planId());
        assertTrue(report.errors().stream().anyMatch(error -> error.column().equals("系统标识") && error.message().contains("曾复用")));
        verifyNoInteractions(f.goodsService);
        report = f.service.detect(workbook("", "现有货品", "222", "", ""));
        assertNotNull(report.planId());
        assertTrue(report.errors().isEmpty());
        assertEquals(1, report.addedRows());
        assertTrue(report.reviewRows().isEmpty());
        report = f.service.detect(workbookWithUuid(f.goods.getId().toString()));
        assertTrue(report.errors().isEmpty(), report.errors().toString());
        assertEquals(1, report.unchangedRows());
    }

    @Test void aDeletedGoodsRestoresByItsOwnUuidRegardlessOfSiblingDeletedRowsSharingTheCode() throws Exception {
        Fixture f = fixture();
        f.goods.setDeleted(true);
        var explicit = f.service.detect(workbookWithUuid(f.goods.getId().toString()));
        assertTrue(explicit.errors().isEmpty(), explicit.errors().toString());
        assertEquals(1, explicit.restorableRows());
        assertNotNull(explicit.planId());
    }

    private static GoodsSaveRequest captured(Fixture f) {
        var request = org.mockito.ArgumentCaptor.forClass(GoodsSaveRequest.class);
        verify(f.goodsService).updateImported(eq(f.goods.getId()), request.capture());
        return request.getValue();
    }
    private static GoodsSaveRequest capturedAgain(Fixture f) { return captured(f); }

    private static Fixture fixture() {
        authorities("goods:import", "goods:edit", "goods:sales:edit", "goods:purchase:edit");
        GoodsRepository repo = mock(GoodsRepository.class);
        GoodsService goodsService = mock(GoodsService.class);
        MaterialCategoryRepository categories = mock(MaterialCategoryRepository.class);
        ColorRepository colors = mock(ColorRepository.class);
        UnitRepository units = mock(UnitRepository.class);
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        SecurityContextCurrentUser user = mock(SecurityContextCurrentUser.class);
        when(user.requireId()).thenReturn(UUID.randomUUID());
        MaterialCategory category = category("成品");
        Goods goods = goods(category, "G1", "现有货品");
        when(repo.findImportIdentities()).thenAnswer(call -> List.of(identity(goods)));
        when(repo.findByCodeAndDeletedFalse("G1")).thenReturn(Optional.of(goods));
        when(repo.findById(goods.getId())).thenReturn(Optional.of(goods));
        when(categories.findByDeletedFalseOrderBySortOrderAscNameAsc()).thenReturn(List.of(category));
        when(colors.findAll()).thenReturn(List.of());
        when(units.findAll()).thenReturn(List.of());
        var service = GoodsImportIdentifierAvailabilityFixture.allowAll(new GoodsImportService(goodsService, repo, null, categories,
                null, colors, null, units, em, user, null));
        GoodsMasterWriteAccessPort access = mock(GoodsMasterWriteAccessPort.class);
        ReflectionTestUtils.setField(service, "writeAccess", access);
        return new Fixture(service, goodsService, repo, goods, category, access);
    }

    private static void authorities(String... permissions) {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("tester", "n/a",
                Arrays.stream(permissions).map(SimpleGrantedAuthority::new).toList()));
    }
    private static MaterialCategory category(String name) {
        MaterialCategory category = new MaterialCategory();
        category.setId(UUID.randomUUID()); category.setName(name); return category;
    }
    private static Goods goods(MaterialCategory category, String code, String name) {
        Goods goods = new Goods();
        goods.setId(UUID.randomUUID()); goods.setVersion(8); goods.setCode(code);
        goods.setName(name); goods.setCategory(category); goods.setStatus("使用"); return goods;
    }
    private static GoodsImportIdentity identity(Goods goods) {
        return new GoodsImportIdentity(goods.getId(), goods.getVersion(), goods.getCode(), goods.getName(),
                goods.getCategory() == null ? null : goods.getCategory().getId(), goods.isDeleted(), goods.getOwnerEmployeeId());
    }
    private static byte[] workbook(String code, String name, String customerModel, String customerName, String spec) throws Exception {
        return workbook(code, name, customerModel, customerName, spec, null);
    }
    private static byte[] workbook(String code, String name, String customerModel, String customerName, String spec,
                                   String goodsId) throws Exception {
        try (var book = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            var sheet = book.createSheet("货品");
            var header = sheet.createRow(0);
            String[] titles = {"编号", "名称", "类别", "客户型号", "客户品名", "规格", "系统标识"};
            for (int i = 0; i < titles.length; i++) header.createCell(i).setCellValue(titles[i]);
            var row = sheet.createRow(1);
            String[] values = {code, name, "成品", customerModel, customerName, spec, goodsId};
            for (int i = 0; i < values.length; i++) {
                if (values[i] != null && !values[i].isEmpty()) row.createCell(i).setCellValue(values[i]);
            }
            book.write(out); return out.toByteArray();
        }
    }
    private static byte[] workbookWithUuid(String id) throws Exception {
        return workbookWithUuid("G1", id);
    }
    private static byte[] workbookWithoutCode(String id, String customerName) throws Exception {
        try (var book = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            var sheet = book.createSheet("货品");
            var header = sheet.createRow(0); var row = sheet.createRow(1);
            String[] titles = {"名称", "类别", "系统标识", "客户品名"};
            String[] values = {"现有货品", "成品", id, customerName};
            for (int i = 0; i < titles.length; i++) {
                header.createCell(i).setCellValue(titles[i]); row.createCell(i).setCellValue(values[i]);
            }
            book.write(out); return out.toByteArray();
        }
    }
    private static byte[] workbookWithUuid(String code, String id) throws Exception {
        try (var book = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            var sheet = book.createSheet("货品");
            var header = sheet.createRow(0);
            String[] titles = {"编号", "名称", "类别", "货品UUID"};
            for (int i = 0; i < titles.length; i++) header.createCell(i).setCellValue(titles[i]);
            var row = sheet.createRow(1);
            String[] values = {code, "现有货品", "成品", id};
            for (int i = 0; i < values.length; i++) row.createCell(i).setCellValue(values[i]);
            book.write(out); return out.toByteArray();
        }
    }
    private record Fixture(GoodsImportService service, GoodsService goodsService, GoodsRepository repo,
                           Goods goods, MaterialCategory category, GoodsMasterWriteAccessPort access) {}
}
