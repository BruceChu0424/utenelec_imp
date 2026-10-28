package com.uten.imp.features.master.goods.importing;

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
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Partial files must isolate complete problem groups and never replay successful rows. */
class GoodsImportPartialSafetyTest {
    @AfterEach void clearSecurity() { SecurityContextHolder.clearContext(); }

    @Test void duplicateGroupsAreAllIsolatedWhileTheNormalRowImports() throws Exception {
        Fixture f = fixture();
        byte[] file = mixedWorkbook();
        var report = f.importer.detect(file, Map.of(), Set.of());

        assertEquals(Set.of(3, 4), errorRows(report));
        assertEquals(List.of(3, 4), report.problemRows().stream().map(GoodsImportProblemRow::rowNum).toList());
        assertEquals(List.of(2, 3, 4), report.previewRows().stream().map(GoodsImportProblemRow::rowNum).toList(),
                "Confirmation must include normal rows together with the rows requiring repair");
        assertEquals("正常规格", report.previewRows().getFirst().cells().get("spec"));
        assertEquals(List.of(2), report.readyRowNums());
        assertEquals(1, report.readyToImport());
        assertEquals(1, report.addedRows());
        assertNotNull(report.planId());
        verifyNoInteractions(f.goodsService);

        var result = f.importer.commit(report.planId(), file, "mixed.xlsx", Set.of(), Map.of(), Set.of());

        assertEquals(1, result.createdCount());
        assertEquals(List.of("GOOD"), f.saved.stream().map(GoodsSaveRequest::getCode).toList());
        assertEquals("正常规格", f.saved.getFirst().getSpec());
        assertEquals(f.category.getId(), f.saved.getFirst().getCategoryId());
        verify(f.goodsService, never()).updateImported(any(), any());
        verify(f.goodsService, never()).restoreImported(any(), any());
    }

    @Test void correctingRemainingRowsExcludesSuccessfulRowsAndRetainsOriginalBytes() throws Exception {
        Fixture f = fixture();
        byte[] file = mixedWorkbook();
        byte[] original = file.clone();
        var first = f.importer.detect(file, Map.of(), Set.of());
        f.importer.commit(first.planId(), file, "mixed.xlsx", Set.of(), Map.of(), Set.of());

        Map<Integer, String> corrections = Map.of(3, "DUP-A", 4, "DUP-B");
        Set<Integer> completed = Set.of(2);
        var repaired = f.importer.detect(file, corrections, completed);

        assertTrue(repaired.errors().isEmpty(), repaired.errors().toString());
        assertEquals(List.of(3, 4), repaired.readyRowNums());
        assertEquals(List.of(3, 4), repaired.previewRows().stream().map(GoodsImportProblemRow::rowNum).toList(),
                "Successful/excluded rows must not reappear in confirmation");
        assertEquals(2, repaired.addedRows());
        assertTrue(repaired.reviewRows().isEmpty());
        var result = f.importer.commit(repaired.planId(), file, "mixed.xlsx", Set.of(), corrections, completed);

        assertEquals(2, result.createdCount());
        assertEquals(List.of("GOOD", "DUP-A", "DUP-B"), f.saved.stream().map(GoodsSaveRequest::getCode).toList());
        assertEquals(List.of("正常规格", "问题规格一", "问题规格二"),
                f.saved.stream().map(GoodsSaveRequest::getSpec).toList());
        assertArrayEquals(original, file, "Number corrections must never replace or rewrite the source workbook");
        assertThrows(ApiException.class, () -> f.importer.commit(
                repaired.planId(), file, "mixed.xlsx", Set.of(), corrections, completed));
        assertEquals(3, f.saved.size(), "An uncertain replay of the consumed plan must not create any row again");
        verify(f.goodsService, never()).updateImported(any(), any());
    }

    @Test void correctedDuplicateNumbersMayAllBeBlankWithoutLosingAnyRow() throws Exception {
        Fixture f = fixture();
        byte[] file = mixedWorkbook();
        Map<Integer, String> corrections = Map.of(3, "", 4, "");
        var report = f.importer.detect(file, corrections, Set.of(2));

        assertTrue(report.errors().isEmpty(), report.errors().toString());
        assertEquals(List.of(3, 4), report.readyRowNums());
        var result = f.importer.commit(report.planId(), file, "blank-corrections.xlsx",
                Set.of(), corrections, Set.of(2));

        assertEquals(2, result.createdCount());
        assertEquals(List.of("", ""), f.saved.stream().map(GoodsSaveRequest::getCode).toList());
        assertEquals(2, f.localGoods.size());
        assertEquals(2, f.localGoods.values().stream().map(Goods::getCode).distinct().count());
    }

    @Test void omissionOrMutationOfExcludedRowsCannotBroadenAReviewedPlan() throws Exception {
        for (Set<Integer> submitted : List.of(Set.<Integer>of(), Set.of(2, 3))) {
            Fixture f = fixture();
            byte[] file = mixedWorkbook();
            Map<Integer, String> corrections = Map.of(3, "DUP-A", 4, "DUP-B");
            var report = f.importer.detect(file, corrections, Set.of(2));

            assertNotNull(report.planId());
            assertThrows(ApiException.class, () -> f.importer.commit(report.planId(), file, "tampered.xlsx",
                    Set.of(), corrections, submitted));
            assertTrue(f.saved.isEmpty());
            verifyNoInteractions(f.goodsService);
        }
    }

    @Test void callerMutationDoesNotChangeTheExcludedRowsCapturedByThePlan() throws Exception {
        Fixture f = fixture();
        byte[] file = workbook(
                row("ONE", "一", "规格一"), row("TWO", "二", "规格二"), row("THREE", "三", "规格三"));
        Set<Integer> exclusions = new HashSet<>(Set.of(2));
        var report = f.importer.detect(file, Map.of(), exclusions);
        exclusions.add(3);

        var result = f.importer.commit(report.planId(), file, "immutable-selection.xlsx",
                Set.of(), Map.of(), Set.of(2));

        assertEquals(2, result.createdCount());
        assertEquals(List.of("TWO", "THREE"), f.saved.stream().map(GoodsSaveRequest::getCode).toList());
    }

    @Test void rowLevelNumericErrorsDoNotBlockTheNormalRowOrCreateProblemReferences() throws Exception {
        Fixture f = fixture();
        byte[] file = workbook(row("GOOD", "正常货品", "正常规格"),
                new String[]{"BAD", "问题货品", "问题专用新分类", "问题规格", "", "不是数字"});
        var report = f.importer.detect(file, Map.of(), Set.of());

        assertEquals(Set.of(3), errorRows(report));
        assertEquals(List.of(2), report.readyRowNums());
        assertTrue(report.willCreateCategories().isEmpty(),
                "Invalid rows must not create or advertise references in the normal-row transaction");
        assertNotNull(report.planId());
        var result = f.importer.commit(report.planId(), file, "numeric-error.xlsx", Set.of(), Map.of(), Set.of());

        assertEquals(1, result.createdCount());
        assertEquals(0, result.createdCategories());
        assertEquals(List.of("GOOD"), f.saved.stream().map(GoodsSaveRequest::getCode).toList());
    }

    @Test void duplicateLocalUuidTargetsAreAllIsolatedEvenWhenTheirNumbersDiffer() throws Exception {
        Fixture f = fixture();
        Goods existing = new Goods();
        existing.setId(UUID.randomUUID()); existing.setVersion(1); existing.setCode("CURRENT");
        existing.setName("当前货品"); existing.setCategory(f.category); existing.setStatus("使用");
        f.localGoods.put(existing.getId(), existing);
        byte[] file = workbook(row("GOOD", "正常货品", "正常规格"),
                new String[]{"NEXT-A", "当前货品", "成品", "", existing.getId().toString(), "1"},
                new String[]{"NEXT-B", "当前货品", "成品", "", existing.getId().toString(), "1"});
        var report = f.importer.detect(file, Map.of(), Set.of());

        assertEquals(Set.of(3, 4), errorRows(report));
        assertEquals(List.of(2), report.readyRowNums());
        assertTrue(report.reviewRows().isEmpty(), "Problem-group updates must not leak into the normal-row review");
        f.importer.commit(report.planId(), file, "duplicate-uuid.xlsx", Set.of(), Map.of(), Set.of());

        assertEquals(List.of("GOOD"), f.saved.stream().map(GoodsSaveRequest::getCode).toList());
        assertEquals("CURRENT", existing.getCode());
        verify(f.goodsService, never()).updateImported(any(), any());
    }

    @Test void aFileWithOnlyDuplicateProblemRowsHasNoCommittablePlan() throws Exception {
        Fixture f = fixture();
        var report = f.importer.detect(workbook(row("DUP", "一", "一"), row("DUP", "二", "二")),
                Map.of(), Set.of());

        assertEquals(Set.of(2, 3), errorRows(report));
        assertTrue(report.readyRowNums().isEmpty());
        assertEquals(0, report.readyToImport());
        assertNull(report.planId());
        verifyNoInteractions(f.goodsService);
    }

    @Test void unchangedNormalRowsCanBeProcessedWhileProblemRowsRemain() throws Exception {
        Fixture f = fixture();
        Goods existing = new Goods();
        existing.setId(UUID.randomUUID()); existing.setVersion(1); existing.setCode("CURRENT");
        existing.setName("当前货品"); existing.setCategory(f.category); existing.setStatus("使用");
        existing.setMinOrderQty(BigDecimal.ONE);
        f.localGoods.put(existing.getId(), existing);
        byte[] file = workbook(row("CURRENT", "当前货品", ""),
                row("DUP", "问题一", ""), row("DUP", "问题二", ""));
        // 匹配只认系统标识：未变化行需携带 UUID 才能对上在库货品。
        try (var book = new XSSFWorkbook(new java.io.ByteArrayInputStream(file));
             var out = new ByteArrayOutputStream()) {
            book.getSheetAt(0).getRow(1).createCell(4).setCellValue(existing.getId().toString());
            book.write(out); file = out.toByteArray();
        }
        var report = f.importer.detect(file, Map.of(), Set.of());

        assertEquals(List.of(2), report.readyRowNums());
        assertEquals(0, report.readyToImport());
        assertEquals(1, report.unchangedRows());
        assertNotNull(report.planId());
        var result = f.importer.commit(report.planId(), file, "unchanged-normal.xlsx",
                Set.of(), Map.of(), Set.of());

        assertEquals(0, result.importedCount());
        assertEquals(1, result.unchangedCount());
        assertNull(result.batchId());
        verifyNoInteractions(f.goodsService);
    }

    @Test void everyImportModeReturnsNormalRowsForConfirmationBeforeAnyWrite() throws Exception {
        for (GoodsImportMode mode : GoodsImportMode.values()) {
            Fixture f = fixture();
            byte[] file = workbook(row("NORMAL", "待确认货品", "文件规格"));
            if (mode == GoodsImportMode.UPDATE_ONLY) {
                var existing = new Goods();
                existing.setId(UUID.randomUUID()); existing.setVersion(1); existing.setCode("NORMAL");
                existing.setName("待确认货品"); existing.setSpec("文件规格"); existing.setCategory(f.category);
                existing.setStatus("使用"); existing.setMinOrderQty(BigDecimal.ONE);
                f.localGoods.put(existing.getId(), existing);
                try (var book = new XSSFWorkbook(new java.io.ByteArrayInputStream(file));
                     var out = new ByteArrayOutputStream()) {
                    book.getSheetAt(0).getRow(1).getCell(4).setCellValue(existing.getId().toString());
                    book.write(out); file = out.toByteArray();
                }
            }
            var report = f.importer.detect(file, Map.of(), Set.of(), Map.of(), mode);

            assertTrue(report.errors().isEmpty(), mode + ": " + report.errors());
            assertEquals(List.of(2), report.readyRowNums(), mode.toString());
            assertEquals(1, report.previewRows().size(), mode.toString());
            var preview = report.previewRows().getFirst();
            assertEquals("NORMAL", preview.code());
            assertEquals("待确认货品", preview.name());
            assertEquals("成品", preview.categoryPath());
            assertEquals("文件规格", preview.cells().get("spec"));
            assertNotNull(report.planId());
            verifyNoInteractions(f.goodsService);
        }
    }

    @Test void selectedPreviewUsesEffectiveCategoryNameAndEnglishNameCorrections() throws Exception {
        Fixture f = fixture();
        byte[] file = mixedWorkbook();
        Map<Integer, Map<String, String>> cells = Map.of(3, Map.of("code", "FIXED",
                "name", "确认后名称", "nameEn", "Reviewed name", "categoryPath", "成品 / 新系列"));

        var report = f.importer.detect(file, Map.of(), Set.of(2, 4), cells, GoodsImportMode.CREATE_ONLY);

        assertTrue(report.errors().isEmpty(), report.errors().toString());
        assertEquals(List.of(3), report.readyRowNums());
        assertEquals(List.of(3), report.previewRows().stream().map(GoodsImportProblemRow::rowNum).toList());
        var preview = report.previewRows().getFirst();
        assertEquals("FIXED", preview.code());
        assertEquals("确认后名称", preview.name());
        assertEquals("成品 / 新系列", preview.categoryPath());
        assertEquals("Reviewed name", preview.cells().get("nameEn"));
        assertEquals("问题规格一", preview.cells().get("spec"));
        assertEquals(List.of("成品/新系列"), report.willCreateCategories());
        assertThrows(UnsupportedOperationException.class, () -> preview.cells().put("name", "changed"));
        assertThrows(UnsupportedOperationException.class, () -> report.previewRows().clear());
        verifyNoInteractions(f.goodsService);
    }

    private static Set<Integer> errorRows(GoodsImportReport report) {
        return report.errors().stream().map(GoodsImportError::rowNum).collect(java.util.stream.Collectors.toSet());
    }

    private static byte[] mixedWorkbook() throws Exception {
        return workbook(row("GOOD", "正常货品", "正常规格"),
                row("DUP", "问题货品一", "问题规格一"), row("DUP", "问题货品二", "问题规格二"));
    }

    private static String[] row(String code, String name, String spec) {
        return new String[]{code, name, "成品", spec, "", "1"};
    }

    private static byte[] workbook(String[]... values) throws Exception {
        try (var workbook = new XSSFWorkbook(); var output = new ByteArrayOutputStream()) {
            var sheet = workbook.createSheet("货品");
            String[] titles = {"编号", "货品名称", "类别", "规格", "系统标识", "最小起订量"};
            var header = sheet.createRow(0);
            for (int column = 0; column < titles.length; column++) header.createCell(column).setCellValue(titles[column]);
            for (int index = 0; index < values.length; index++) {
                var row = sheet.createRow(index + 1);
                for (int column = 0; column < values[index].length; column++) {
                    row.createCell(column).setCellValue(values[index][column]);
                }
            }
            workbook.write(output);
            return output.toByteArray();
        }
    }

    private static Fixture fixture() {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("tester", "n/a",
                Arrays.stream(new String[]{"goods:import", "goods:edit", "goods:sales:edit", "goods:purchase:edit"})
                        .map(SimpleGrantedAuthority::new).toList()));
        var category = new MaterialCategory();
        category.setId(UUID.randomUUID()); category.setName("成品");
        var categories = mock(MaterialCategoryRepository.class);
        when(categories.findByDeletedFalseOrderBySortOrderAscNameAsc()).thenReturn(List.of(category));
        var colors = mock(ColorRepository.class);
        when(colors.findAll()).thenReturn(List.of());
        var units = mock(UnitRepository.class);
        when(units.findAll()).thenReturn(List.of());
        Map<UUID, Goods> localGoods = new LinkedHashMap<>();
        var repository = mock(GoodsRepository.class);
        when(repository.findImportIdentities()).thenAnswer(call -> localGoods.values().stream().map(goods ->
                new GoodsImportIdentity(goods.getId(), goods.getVersion(), goods.getCode(), goods.getName(),
                        goods.getCategory().getId(), goods.isDeleted(), goods.getOwnerEmployeeId())).toList());
        when(repository.findById(any())).thenAnswer(call -> Optional.ofNullable(localGoods.get(call.getArgument(0))));
        when(repository.findByCodeAndDeletedFalse(anyString())).thenAnswer(call -> localGoods.values().stream()
                .filter(goods -> !goods.isDeleted() && goods.getCode().equals(call.getArgument(0))).findFirst());
        when(repository.existsByCodeAndDeletedFalse(anyString())).thenAnswer(call -> localGoods.values().stream()
                .anyMatch(goods -> !goods.isDeleted() && goods.getCode().equals(call.getArgument(0))));
        var service = mock(GoodsService.class);
        List<GoodsSaveRequest> saved = new ArrayList<>();
        when(service.saveImported(any())).thenAnswer(call -> {
            GoodsSaveRequest request = call.getArgument(0);
            saved.add(request);
            var created = new Goods();
            created.setId(UUID.randomUUID()); created.setVersion(1); created.setName(request.getName());
            created.setCategory(category); created.setStatus("使用");
            created.setCode(request.getCode() == null || request.getCode().isBlank()
                    ? "AUTO" + saved.size() : request.getCode());
            localGoods.put(created.getId(), created);
            return created.getId();
        });
        var em = mock(EntityManager.class);
        var query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        var actor = mock(SecurityContextCurrentUser.class);
        when(actor.requireId()).thenReturn(UUID.randomUUID());
        var importer = new GoodsImportService(service, repository, null, categories,
                null, colors, null, units, em, actor, null);
        ReflectionTestUtils.setField(importer, "writeAccess", mock(GoodsMasterWriteAccessPort.class));
        return new Fixture(importer, service, category, localGoods, saved);
    }

    private record Fixture(GoodsImportService importer, GoodsService goodsService, MaterialCategory category,
                           Map<UUID, Goods> localGoods, List<GoodsSaveRequest> saved) {}
}
