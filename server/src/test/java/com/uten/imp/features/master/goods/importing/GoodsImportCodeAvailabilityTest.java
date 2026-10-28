package com.uten.imp.features.master.goods.importing;

import com.uten.imp.application.port.GoodsMasterWriteAccessPort;
import com.uten.imp.common.mastercode.MasterIdentifierAvailabilityService;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.Goods;
import com.uten.imp.features.master.goods.GoodsRepository;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
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
import java.util.Optional;
import java.util.UUID;

import static com.uten.imp.common.mastercode.MasterIdentifierAvailabilityService.Domain.GOODS;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Import detection must use the same identity and inherited-prefix rules as goods writes. */
class GoodsImportCodeAvailabilityTest {
    @AfterEach void clearAuthentication() { SecurityContextHolder.clearContext(); }

    @Test void unavailableHistoryDeletedAndOtherDomainCodesAreIsolatedBeforeConfirmation() throws Exception {
        var category = category("成品", null);
        var fixture = fixture(List.of(category));
        for (String code : List.of("HISTORICAL", "DELETED", "OTHER-DOMAIN")) {
            when(fixture.availability.checkForTargetCategory(eq(GOODS), eq(code), isNull(), eq(category.getId())))
                    .thenReturn(new MasterIdentifierAvailabilityService.Availability(code, false,
                            "编号已存在或已被历史资料使用，请更换编号"));
        }

        var report = fixture.importer.detect(workbook(
                row("HISTORICAL", "历史编号货品", "成品", null),
                row("DELETED", "已删除编号货品", "成品", null),
                row("OTHER-DOMAIN", "其他资料编号货品", "成品", null),
                row("FREE", "正常货品", "成品", null)));

        assertEquals(List.of(2, 3, 4), report.problemRows().stream().map(GoodsImportProblemRow::rowNum).toList());
        assertEquals(3, report.errors().size());
        assertTrue(report.errors().stream().allMatch(error -> "编号".equals(error.column())));
        assertEquals(List.of(5), report.readyRowNums());
        assertEquals(1, report.readyToImport());
        assertEquals(1, report.addedRows());
        assertNotNull(report.planId());
        verifyNoInteractions(fixture.goodsService);
    }

    @Test void reviewedUuidRenameChecksTheExistingIdentityRatherThanANewGoods() throws Exception {
        var category = category("成品", null);
        var fixture = fixture(List.of(category));
        var goods = goods("CURRENT", category, false);
        when(fixture.repository.findById(goods.getId())).thenReturn(Optional.of(goods));

        var report = fixture.importer.detect(workbook(row("NEXT", goods.getName(), "成品", goods.getId())));

        assertTrue(report.errors().isEmpty(), report.errors().toString());
        assertEquals(1, report.reviewRows().size());
        verify(fixture.availability).checkForTargetCategory(GOODS, "NEXT", goods.getId(), category.getId());
        verify(fixture.availability, never()).checkForRestore(any(), anyString(), any(), any());
    }

    @Test void unavailableUuidRenameIsReportedOnItsNumberBeforeReviewOrWrite() throws Exception {
        var category = category("成品", null);
        var fixture = fixture(List.of(category));
        var goods = goods("CURRENT", category, false);
        when(fixture.repository.findById(goods.getId())).thenReturn(Optional.of(goods));
        when(fixture.availability.checkForTargetCategory(GOODS, "OCCUPIED", goods.getId(), category.getId()))
                .thenReturn(new MasterIdentifierAvailabilityService.Availability("OCCUPIED", false,
                        "编号已存在或已被历史资料使用，请更换编号"));

        var report = fixture.importer.detect(workbook(row("OCCUPIED", goods.getName(), "成品", goods.getId())));

        assertEquals(1, report.errors().size());
        assertEquals("编号", report.errors().getFirst().column());
        assertEquals(0, report.readyToImport());
        assertNull(report.planId());
        assertTrue(report.reviewRows().isEmpty());
        verifyNoInteractions(fixture.goodsService);
    }

    @Test void restoringUuidWithBlankFileCodeChecksItsOriginalCodeAndIdentity() throws Exception {
        var category = category("成品", null);
        var fixture = fixture(List.of(category));
        var deleted = goods("ORIGINAL", category, true);
        when(fixture.repository.findById(deleted.getId())).thenReturn(Optional.of(deleted));

        var report = fixture.importer.detect(workbook(row("", deleted.getName(), "成品", deleted.getId())));

        assertTrue(report.errors().isEmpty(), report.errors().toString());
        assertEquals(1, report.restorableRows());
        assertNotNull(report.planId());
        verify(fixture.availability).checkForRestore(GOODS, "ORIGINAL", deleted.getId(), category.getId());
        verify(fixture.availability, never()).checkForTargetCategory(any(), anyString(), any(), any());
        verify(fixture.goodsService).requireRestoreImportedWriteAccess(deleted.getId());
    }

    @Test void freshAndProvenReusableCodesBothRemainEligibleForNewGoods() throws Exception {
        var category = category("成品", null);
        var fixture = fixture(List.of(category));

        var report = fixture.importer.detect(workbook(
                row("FRESH", "新编号货品", "成品", null),
                row("REUSABLE", "可回用编号货品", "成品", null)));

        assertTrue(report.errors().isEmpty(), report.errors().toString());
        assertEquals(List.of(2, 3), report.readyRowNums());
        assertEquals(2, report.addedRows());
        assertEquals(2, report.readyToImport());
        assertNotNull(report.planId());
        verify(fixture.availability).checkForTargetCategory(GOODS, "FRESH", null, category.getId());
        verify(fixture.availability).checkForTargetCategory(GOODS, "REUSABLE", null, category.getId());
        verifyNoInteractions(fixture.goodsService);
    }

    @Test void newChildCategoryUsesItsNearestExistingAncestorForManagedSequenceValidation() throws Exception {
        var root = category("成品", null);
        var parent = category("系列", root);
        parent.setCodePrefix("C2");
        var fixture = fixture(List.of(root, parent));
        when(fixture.availability.checkForTargetCategory(GOODS, "C2000123", null, parent.getId()))
                .thenReturn(new MasterIdentifierAvailabilityService.Availability("C2000123", false,
                        "编号数字序号已被使用：123"));

        var report = fixture.importer.detect(workbook(row("C2000123", "新分类货品", "成品 / 系列 / 新建 / 新建", null)));

        assertEquals(1, report.errors().size());
        assertEquals("编号", report.errors().getFirst().column());
        assertTrue(report.errors().getFirst().message().contains("数字序号"));
        assertNull(report.planId());
        assertTrue(report.willCreateCategories().isEmpty(), "A blocked row must not advertise new categories as ready work");
        verify(fixture.availability).checkForTargetCategory(GOODS, "C2000123", null, parent.getId());
        verifyNoInteractions(fixture.goodsService);
    }

    @Test void blankNewCodeRemainsEligibleForAutomaticAllocationWithoutExplicitCodeLookup() throws Exception {
        var category = category("成品", null);
        var fixture = fixture(List.of(category));

        var report = fixture.importer.detect(workbook(row("", "自动编号货品", "成品", null)));

        assertTrue(report.errors().isEmpty(), report.errors().toString());
        assertEquals(1, report.readyToImport());
        assertNotNull(report.planId());
        verifyNoInteractions(fixture.availability);
    }

    @Test void whollyNewCategoryForUuidUpdateExplicitlyUsesTheDomainFallback() throws Exception {
        var currentCategory = category("现有分类", null);
        currentCategory.setCodePrefix("C2");
        var fixture = fixture(List.of(currentCategory));
        var goods = goods("CURRENT", currentCategory, false);
        when(fixture.repository.findById(goods.getId())).thenReturn(Optional.of(goods));

        var report = fixture.importer.detect(workbook(row("HP000123", goods.getName(), "全新分类", goods.getId())));

        assertTrue(report.errors().isEmpty(), report.errors().toString());
        verify(fixture.availability).checkForTargetCategory(GOODS, "HP000123", goods.getId(), null);
    }

    @Test void blankUuidImportCodePreservesTheOriginalLabelWhileCheckingTheNewCategory() throws Exception {
        var currentCategory = category("现有分类", null);
        var targetCategory = category("目标分类", null);
        var fixture = fixture(List.of(currentCategory, targetCategory));
        var goods = goods("HP000123", currentCategory, false);
        when(fixture.repository.findById(goods.getId())).thenReturn(Optional.of(goods));

        var report = fixture.importer.detect(workbook(row("", goods.getName(), "目标分类", goods.getId())));

        assertTrue(report.errors().isEmpty(), report.errors().toString());
        verify(fixture.availability).checkForTargetCategory(GOODS, "HP000123", goods.getId(), targetCategory.getId());
    }

    @Test void unknownFileUuidChecksNewCodeWithoutGrantingTheForeignIdentityOwnership() throws Exception {
        var category = category("成品", null);
        var fixture = fixture(List.of(category));

        var report = fixture.importer.detect(workbook(row("FRESH", "历史库货品", "成品", UUID.randomUUID())));

        assertTrue(report.errors().isEmpty(), report.errors().toString());
        assertEquals(1, report.addedRows());
        verify(fixture.availability).checkForTargetCategory(GOODS, "FRESH", null, category.getId());
    }

    private static Fixture fixture(List<MaterialCategory> tree) {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("tester", "n/a",
                Arrays.stream(new String[]{"goods:import", "goods:edit", "goods:sales:edit", "goods:purchase:edit"})
                        .map(SimpleGrantedAuthority::new).toList()));
        var categories = mock(MaterialCategoryRepository.class);
        when(categories.findByDeletedFalseOrderBySortOrderAscNameAsc()).thenReturn(tree);
        var colors = mock(ColorRepository.class);
        when(colors.findAll()).thenReturn(List.of());
        var units = mock(UnitRepository.class);
        when(units.findAll()).thenReturn(List.of());
        var repository = mock(GoodsRepository.class);
        var service = mock(GoodsService.class);
        var actor = mock(SecurityContextCurrentUser.class);
        when(actor.requireId()).thenReturn(UUID.randomUUID());
        var availability = mock(MasterIdentifierAvailabilityService.class);
        when(availability.checkForTargetCategory(any(), anyString(), any(), any())).thenAnswer(invocation ->
                new MasterIdentifierAvailabilityService.Availability(invocation.getArgument(1), true, null));
        when(availability.checkForRestore(any(), anyString(), any(), any())).thenAnswer(invocation ->
                new MasterIdentifierAvailabilityService.Availability(invocation.getArgument(1), true, null));
        var importer = new GoodsImportService(service, repository, null, categories,
                null, colors, null, units, null, actor, null);
        ReflectionTestUtils.setField(importer, "identifierAvailability", availability);
        ReflectionTestUtils.setField(importer, "writeAccess", mock(GoodsMasterWriteAccessPort.class));
        return new Fixture(importer, repository, service, availability);
    }

    private static MaterialCategory category(String name, MaterialCategory parent) {
        var category = new MaterialCategory();
        category.setId(UUID.randomUUID());
        category.setName(name);
        category.setParent(parent);
        return category;
    }

    private static Goods goods(String code, MaterialCategory category, boolean deleted) {
        var goods = new Goods();
        goods.setId(UUID.randomUUID());
        goods.setCode(code);
        goods.setName("货品");
        goods.setCategory(category);
        goods.setDeleted(deleted);
        goods.setStatus("使用");
        goods.setMinOrderQty(BigDecimal.ONE);
        return goods;
    }

    private static String[] row(String code, String name, String category, UUID id) {
        return new String[]{code, name, category, id == null ? "" : id.toString()};
    }

    private static byte[] workbook(String[]... rows) throws Exception {
        try (var workbook = new XSSFWorkbook(); var output = new ByteArrayOutputStream()) {
            var sheet = workbook.createSheet("货品");
            var header = sheet.createRow(0);
            String[] titles = {"编号", "货品名称", "类别", "系统标识"};
            for (int column = 0; column < titles.length; column++) header.createCell(column).setCellValue(titles[column]);
            for (int index = 0; index < rows.length; index++) {
                var row = sheet.createRow(index + 1);
                for (int column = 0; column < rows[index].length; column++) row.createCell(column).setCellValue(rows[index][column]);
            }
            workbook.write(output);
            return output.toByteArray();
        }
    }

    private record Fixture(GoodsImportService importer, GoodsRepository repository, GoodsService goodsService,
                           MasterIdentifierAvailabilityService availability) { }
}
