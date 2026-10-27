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
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Typed cell fixes share parsing rules, preserve source bytes and stay bound to their reviewed plan. */
class GoodsImportCellCorrectionsSafetyTest {
    @AfterEach void clearSecurity() { SecurityContextHolder.clearContext(); }

    @Test void normalRowsImportBeforeNameSourceAndPriceAreRepairedInTheRemainingRow() throws Exception {
        Fixture f = fixture();
        byte[] file = workbook(row("GOOD", "正常货品", "原规格一", "自制", "10.25"),
                row("BAD", "", "原规格二", "错误来源", "错误价格"));
        byte[] original = file.clone();
        var first = f.importer.detect(file, Map.of(), Set.of(), Map.of());

        assertEquals(List.of(2), first.readyRowNums());
        assertEquals(Set.of(3), errorRows(first));
        var problem = first.problemRows().getFirst();
        assertEquals(3, problem.rowNum());
        assertEquals("", problem.cells().get("name"));
        assertEquals("错误来源", problem.cells().get("sourceType"));
        assertEquals("错误价格", problem.cells().get("price"));
        assertEquals("原规格二", problem.cells().get("spec"));
        var normalResult = f.importer.commit(first.planId(), file, "repair-cells.xlsx",
                Set.of(), Map.of(), Set.of(), Map.of());
        assertEquals(1, normalResult.createdCount());
        assertEquals(List.of("GOOD"), f.saved.stream().map(GoodsSaveRequest::getCode).toList());

        Map<Integer, Map<String, String>> cells = Map.of(3,
                Map.of("name", "修正货品", "sourceType", "采购", "price", "1.2345"));
        var repaired = f.importer.detect(file, Map.of(), Set.of(2), cells);
        assertTrue(repaired.errors().isEmpty(), repaired.errors().toString());
        assertEquals(List.of(3), repaired.readyRowNums());
        assertEquals(1, repaired.addedRows());
        var repairedResult = f.importer.commit(repaired.planId(), file, "repair-cells.xlsx",
                Set.of(), Map.of(), Set.of(2), cells);

        assertEquals(1, repairedResult.createdCount());
        assertEquals(List.of("GOOD", "BAD"), f.saved.stream().map(GoodsSaveRequest::getCode).toList());
        GoodsSaveRequest saved = f.saved.getLast();
        assertEquals("修正货品", saved.getName());
        assertEquals("采购", saved.getSourceType());
        assertEquals(new BigDecimal("1.2345"), saved.getPrice());
        assertEquals("原规格二", saved.getSpec());
        assertEquals(f.category.getId(), saved.getCategoryId());
        assertArrayEquals(original, file);
        verify(f.goodsService, never()).updateImported(any(), any());
        assertThrows(ApiException.class, () -> f.importer.commit(repaired.planId(), file, "replay.xlsx",
                Set.of(), Map.of(), Set.of(2), cells));
        assertEquals(2, f.saved.size());
    }

    @Test void remainingProblemsShowTheEffectiveCorrectedCellsWithoutDiscardingOtherFileValues() throws Exception {
        Fixture f = fixture();
        byte[] file = workbook(row("BAD", "", "保留原规格", "错误来源", "错误价格"));
        var report = f.importer.detect(file, Map.of(), Set.of(), Map.of(2,
                Map.of("name", "已修正名称", "price", "12.3456")));

        assertEquals(Set.of(2), errorRows(report));
        assertNull(report.planId());
        var problem = report.problemRows().getFirst();
        assertEquals("已修正名称", problem.name());
        assertEquals("已修正名称", problem.cells().get("name"));
        assertEquals("12.3456", problem.cells().get("price"));
        assertEquals("错误来源", problem.cells().get("sourceType"));
        assertEquals("保留原规格", problem.cells().get("spec"));
        assertThrows(UnsupportedOperationException.class, () -> problem.cells().put("name", "外部改写"));
        verifyNoInteractions(f.goodsService);
    }

    @Test void omittedOrChangedCellCorrectionsCannotBeCommittedUnderTheOriginalPlan() throws Exception {
        for (Map<Integer, Map<String, String>> submitted : List.of(
                Map.<Integer, Map<String, String>>of(), Map.of(2, Map.of("price", "99.25")))) {
            Fixture f = fixture();
            byte[] file = workbook(row("NEW", "货品", "规格", "自制", "错误价格"));
            var report = f.importer.detect(file, Map.of(), Set.of(), Map.of(2, Map.of("price", "7.25")));

            assertNotNull(report.planId());
            assertThrows(ApiException.class, () -> f.importer.commit(report.planId(), file, "changed-cells.xlsx",
                    Set.of(), Map.of(), Set.of(), submitted));
            assertTrue(f.saved.isEmpty());
            verifyNoInteractions(f.goodsService);
        }
    }

    @Test void callerMutationOfNestedCorrectionMapsDoesNotChangeTheReviewedPlan() throws Exception {
        Fixture f = fixture();
        byte[] file = workbook(row("NEW", "", "保留规格", "错误来源", "错误价格"));
        Map<String, String> edited = new HashMap<>(Map.of("name", "已确认名称", "sourceType", "采购", "price", "3.1415"));
        Map<Integer, Map<String, String>> cells = new HashMap<>();
        cells.put(2, edited);
        var report = f.importer.detect(file, Map.of(), Set.of(), cells);
        edited.put("name", "后来修改");
        edited.put("price", "999");
        cells.put(99, Map.of("name", "无效后加行"));

        Map<Integer, Map<String, String>> confirmed = Map.of(2,
                Map.of("name", "已确认名称", "sourceType", "采购", "price", "3.1415"));
        var result = f.importer.commit(report.planId(), file, "frozen-cells.xlsx",
                Set.of(), Map.of(), Set.of(), confirmed);

        assertEquals(1, result.createdCount());
        assertEquals("已确认名称", f.saved.getFirst().getName());
        assertEquals(new BigDecimal("3.1415"), f.saved.getFirst().getPrice());
    }

    @Test void systemIdentifiersAndNonEditableFieldsCannotBeCorrected() throws Exception {
        for (String field : List.of("goodsId", "id", "UUID", "categoryId", "ownerEmployeeId", "isDeleted")) {
            Fixture f = fixture();
            byte[] file = workbook(row("NEW", "货品", "规格", "自制", "1"));

            assertThrows(ApiException.class, () -> f.importer.detect(file, Map.of(), Set.of(),
                    Map.of(2, Map.of(field, UUID.randomUUID().toString()))), field);
            verifyNoInteractions(f.goodsService);
        }
    }

    @Test void legacyCodeCorrectionsAndCellCodeCorrectionsUseOneCanonicalPlan() throws Exception {
        Fixture f = fixture();
        byte[] file = workbook(row("OLD", "货品", "规格", "自制", "错误价格"));
        var report = f.importer.detect(file, Map.of(2, " new-01 "), Set.of(),
                Map.of(2, Map.of("code", "NEW-01", "price", "4.25")));

        assertTrue(report.errors().isEmpty(), report.errors().toString());
        var result = f.importer.commit(report.planId(), file, "canonical-cells.xlsx", Set.of(), Map.of(), Set.of(),
                Map.of(2, Map.of("code", "NEW-01", "price", "4.25")));

        assertEquals(1, result.createdCount());
        assertEquals("NEW-01", f.saved.getFirst().getCode());
        assertEquals(new BigDecimal("4.25"), f.saved.getFirst().getPrice());
    }

    @Test void conflictingCodeChannelsAreRejectedBeforeAnyImport() throws Exception {
        Fixture f = fixture();
        byte[] file = workbook(row("OLD", "货品", "规格", "自制", "1"));

        assertThrows(ApiException.class, () -> f.importer.detect(file, Map.of(2, "FIRST"), Set.of(),
                Map.of(2, Map.of("code", "SECOND"))));
        verifyNoInteractions(f.goodsService);
    }

    @Test void correctedNamesContainingTotalMarkersDoNotRemoveOriginalDataRows() throws Exception {
        Fixture f = fixture();
        byte[] file = workbook(row("NEW", "货品", "保留规格", "自制", "1"));
        Map<Integer, Map<String, String>> cells = Map.of(2, Map.of("name", "合计连接件"));
        var report = f.importer.detect(file, Map.of(), Set.of(), cells);

        assertTrue(report.errors().isEmpty(), report.errors().toString());
        assertEquals(List.of(2), report.readyRowNums());
        assertEquals(1, report.dataRows());
        var result = f.importer.commit(report.planId(), file, "retained-row.xlsx",
                Set.of(), Map.of(), Set.of(), cells);

        assertEquals(1, result.createdCount());
        assertEquals("合计连接件", f.saved.getFirst().getName());
        assertEquals("保留规格", f.saved.getFirst().getSpec());
    }

    private static Set<Integer> errorRows(GoodsImportReport report) {
        return report.errors().stream().map(GoodsImportError::rowNum).collect(java.util.stream.Collectors.toSet());
    }

    private static String[] row(String code, String name, String spec, String source, String price) {
        return new String[]{code, name, "成品", spec, source, price};
    }

    private static byte[] workbook(String[]... values) throws Exception {
        try (var workbook = new XSSFWorkbook(); var output = new ByteArrayOutputStream()) {
            var sheet = workbook.createSheet("货品");
            String[] titles = {"编号", "货品名称", "类别", "规格", "来源", "价格"};
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
                Arrays.stream(new String[]{"goods:import", "goods:edit", "goods:sales:edit", "goods:purchase:edit",
                                "goods:price:view", "goods:price:edit"})
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
        return new Fixture(importer, service, category, saved);
    }

    private record Fixture(GoodsImportService importer, GoodsService goodsService, MaterialCategory category,
                           List<GoodsSaveRequest> saved) {}
}
