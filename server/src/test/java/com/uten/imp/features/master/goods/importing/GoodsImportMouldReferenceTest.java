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
import com.uten.imp.features.master.mould.Mould;
import com.uten.imp.features.master.mould.MouldRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.GoodsImportIdentifierAvailabilityFixture;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.ReflectionTestUtils;

import java.io.ByteArrayOutputStream;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class GoodsImportMouldReferenceTest {
    @AfterEach void clearSecurity() { SecurityContextHolder.clearContext(); }

    @Test void codeOnlyImportShowsResolvedNameAndWritesTheFrozenUuid() throws Exception {
        var f = fixture();
        byte[] file = workbook(null, "ｍ－００１", "");
        byte[] original = file.clone();
        var report = f.service.detect(file);
        assertTrue(report.errors().isEmpty(), report.errors().toString());
        assertNotNull(report.planId());
        assertEquals("ｍ－００１", report.previewRows().getFirst().cells().get("mouldCode"));
        assertEquals("", report.previewRows().getFirst().cells().get("mouldName"));
        assertEquals("壳体模具", report.previewRows().getFirst().cells().get("resolvedMouldName"));
        f.service.commit(report.planId(), file, "mould.xlsx");
        var capture = ArgumentCaptor.forClass(GoodsSaveRequest.class);
        verify(f.goodsService).saveImported(capture.capture());
        assertEquals(f.mould.getId(), capture.getValue().getMouldId());
        assertNull(capture.getValue().getMouldLegacyId());
        assertTrue(capture.getValue().hasMouldReference());
        assertArrayEquals(original, file);
        assertThrows(ApiException.class, () -> f.service.commit(report.planId(), file, "mould.xlsx"));
        verify(f.goodsService, times(1)).saveImported(any());
    }

    @Test void missingAmbiguousInactiveAndMismatchedMouldsRemainProblemRows() throws Exception {
        for (String failure : List.of("missing", "ambiguous", "inactive", "name", "nameOnly")) {
            var f = fixture();
            if (failure.equals("missing")) when(f.moulds.findByCodeAndDeletedFalse("M-001")).thenReturn(List.of());
            if (failure.equals("ambiguous")) when(f.moulds.findByCodeAndDeletedFalse("M-001"))
                    .thenReturn(List.of(f.mould, mould("M-001", "另一模具")));
            if (failure.equals("inactive")) f.mould.setStatus("禁用");
            byte[] file = workbook(null, failure.equals("nameOnly") ? "" : "M-001",
                    failure.equals("name") || failure.equals("nameOnly") ? "错误名称" : "");
            var report = f.service.detect(file);
            assertFalse(report.errors().isEmpty(), failure);
            assertNull(report.planId(), failure);
            assertEquals(List.of(2), report.problemRows().stream().map(GoodsImportProblemRow::rowNum).toList());
            assertTrue(report.readyRowNums().isEmpty());
            verifyNoInteractions(f.goodsService);
        }
    }

    @Test void existingRelationshipReplacementRequiresReviewAndUsesIdentityEvenWhenNamesMatch() throws Exception {
        var f = fixture();
        var previous = mould("M-OLD", "壳体模具");
        f.goods.setMould(previous);
        f.existing();
        byte[] file = workbook(f.goods.getId(), "M-001", "壳体模具");
        var report = f.service.detect(file);
        var change = report.reviewRows().getFirst().changes().stream()
                .filter(item -> item.field().equals("mouldId")).findFirst().orElseThrow();
        assertEquals("CONFLICT", change.kind());
        assertEquals("M-OLD 壳体模具", change.oldValue());
        assertEquals("M-001 壳体模具", change.newValue());
        var kept = f.service.commit(report.planId(), file, "keep.xlsx");
        assertEquals(1, kept.ignoredCount());
        verifyNoInteractions(f.goodsService);

        report = f.service.detect(file);
        f.service.commit(report.planId(), file, "replace.xlsx", Set.of("goods:2"));
        var capture = ArgumentCaptor.forClass(GoodsSaveRequest.class);
        verify(f.goodsService).updateImported(eq(f.goods.getId()), capture.capture());
        assertEquals(f.mould.getId(), capture.getValue().getMouldId());
    }

    @Test void invalidMouldRowsRemainVisibleWhileIndependentNormalRowsCanCommit() throws Exception {
        var f = fixture();
        byte[] file = workbook(null, "M-001", "");
        try (var book = new XSSFWorkbook(new java.io.ByteArrayInputStream(file));
             var out = new ByteArrayOutputStream()) {
            var row = book.getSheetAt(0).createRow(2);
            String[] values = {"BAD", "错误模具货品", "成品", "", "M-MISSING", ""};
            for (int c = 0; c < values.length; c++) row.createCell(c).setCellValue(values[c]);
            book.write(out); file = out.toByteArray();
        }
        var report = f.service.detect(file);
        assertEquals(List.of(2), report.readyRowNums());
        assertEquals(List.of(3), report.problemRows().stream().map(GoodsImportProblemRow::rowNum).toList());
        assertEquals(2, report.previewRows().size());
        assertEquals("M-MISSING", report.problemRows().getFirst().cells().get("mouldCode"));
        var result = f.service.commit(report.planId(), file, "mixed.xlsx");
        assertEquals(1, result.createdCount());
        verify(f.goodsService).saveImported(argThat(req -> f.mould.getId().equals(req.getMouldId())));
    }

    @Test void blankMouldCodePreservesExistingReferenceAndInactiveEchoIsUnchanged() throws Exception {
        var f = fixture();
        f.goods.setMould(f.mould);
        f.mould.setStatus("禁用");
        f.existing();
        for (String code : List.of("", "M-001")) {
            byte[] file = workbook(f.goods.getId(), code, "");
            var report = f.service.detect(file);
            assertTrue(report.errors().isEmpty(), report.errors().toString());
            assertEquals(1, report.unchangedRows());
            f.service.commit(report.planId(), file, "unchanged.xlsx");
        }
        verifyNoInteractions(f.goodsService);
    }

    @Test void detectionCannotRetargetAfterDeletionRenamingStatusOrIdentityChanges() throws Exception {
        for (String mutation : List.of("deleted", "renamed", "status", "identity", "duplicate")) {
            var f = fixture();
            byte[] file = workbook(null, "M-001", "");
            var report = f.service.detect(file);
            assertNotNull(report.planId());
            switch (mutation) {
                case "deleted" -> f.mould.setDeleted(true);
                case "renamed" -> f.mould.setName("新名称");
                case "status" -> f.mould.setStatus("禁用");
                case "identity" -> when(f.moulds.findById(f.mould.getId())).thenReturn(Optional.empty());
                case "duplicate" -> when(f.moulds.findByCodeAndDeletedFalse("M-001"))
                        .thenReturn(List.of(f.mould, mould("M-001", "新模具")));
            }
            assertThrows(ApiException.class, () -> f.service.commit(report.planId(), file, "stale.xlsx"), mutation);
            verifyNoInteractions(f.goodsService);
        }
    }

    @Test void repeatedMouldCodesResolveOncePerDetectionAndCommitForLargeImports() throws Exception {
        var f = fixture();
        byte[] file;
        try (var book = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            var sheet = book.createSheet("货品");
            String[] headers = {"货品名称", "类别", "模具编号"};
            var header = sheet.createRow(0);
            for (int c = 0; c < headers.length; c++) header.createCell(c).setCellValue(headers[c]);
            for (int i = 1; i <= 2000; i++) {
                var row = sheet.createRow(i);
                row.createCell(0).setCellValue("货品" + i);
                row.createCell(1).setCellValue("成品");
                row.createCell(2).setCellValue("M-001");
            }
            book.write(out); file = out.toByteArray();
        }
        var report = f.service.detect(file);
        assertTrue(report.errors().isEmpty(), report.errors().toString());
        assertEquals(2000, report.readyRowNums().size());
        verify(f.moulds, times(1)).findByCodeAndDeletedFalse("M-001");
        f.service.commit(report.planId(), file, "large.xlsx");
        verify(f.moulds, times(2)).findByCodeAndDeletedFalse("M-001");
        verify(f.moulds, times(1)).findById(f.mould.getId());
        verify(f.goodsService, times(2000)).saveImported(argThat(req -> f.mould.getId().equals(req.getMouldId())));
    }

    private static Fixture fixture() {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("tester", "n/a",
                Arrays.stream(new String[]{"goods:import", "goods:edit"}).map(SimpleGrantedAuthority::new).toList()));
        var categories = mock(MaterialCategoryRepository.class);
        var category = new MaterialCategory(); category.setId(UUID.randomUUID()); category.setName("成品");
        when(categories.findByDeletedFalseOrderBySortOrderAscNameAsc()).thenReturn(List.of(category));
        var goods = new Goods(); goods.setId(UUID.randomUUID()); goods.setCategory(category);
        goods.setCode("G1"); goods.setName("货品"); goods.setStatus("使用");
        var repo = mock(GoodsRepository.class);
        when(repo.findImportIdentities()).thenReturn(List.of());
        var goodsService = mock(GoodsService.class);
        when(goodsService.saveImported(any())).thenAnswer(call -> UUID.randomUUID());
        var em = mock(EntityManager.class); var query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        var user = mock(SecurityContextCurrentUser.class); when(user.requireId()).thenReturn(UUID.randomUUID());
        var service = GoodsImportIdentifierAvailabilityFixture.allowAll(new GoodsImportService(goodsService, repo,
                null, categories, null, mock(ColorRepository.class), null, mock(UnitRepository.class), em, user, null));
        ReflectionTestUtils.setField(service, "writeAccess", mock(GoodsMasterWriteAccessPort.class));
        var moulds = mock(MouldRepository.class);
        var mould = mould("M-001", "壳体模具");
        when(moulds.findByCodeAndDeletedFalse("M-001")).thenReturn(List.of(mould));
        when(moulds.findById(mould.getId())).thenReturn(Optional.of(mould));
        ReflectionTestUtils.setField(service, "mouldRepo", moulds);
        return new Fixture(service, goodsService, repo, goods, moulds, mould);
    }

    private static Mould mould(String code, String name) {
        var mould = new Mould(); mould.setId(UUID.randomUUID()); mould.setCode(code);
        mould.setName(name); mould.setStatus("使用"); return mould;
    }

    private static byte[] workbook(UUID id, String code, String name) throws Exception {
        try (var book = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            var sheet = book.createSheet("货品");
            String[] headers = {"编号", "货品名称", "类别", "系统标识", "模具编号", "模具名称"};
            String[] values = {id == null ? "NEW" : "G1", "货品", "成品", id == null ? "" : id.toString(), code, name};
            var header = sheet.createRow(0); var row = sheet.createRow(1);
            for (int c = 0; c < headers.length; c++) {
                header.createCell(c).setCellValue(headers[c]); row.createCell(c).setCellValue(values[c]);
            }
            book.write(out); return out.toByteArray();
        }
    }

    private record Fixture(GoodsImportService service, GoodsService goodsService, GoodsRepository repo,
                           Goods goods, MouldRepository moulds, Mould mould) {
        void existing() {
            when(repo.findById(goods.getId())).thenReturn(Optional.of(goods));
            when(repo.findImportIdentities()).thenReturn(List.of(new GoodsImportIdentity(goods.getId(),
                    goods.getVersion(), goods.getCode(), goods.getName(), goods.getCategory().getId(), false, null)));
        }
    }
}
