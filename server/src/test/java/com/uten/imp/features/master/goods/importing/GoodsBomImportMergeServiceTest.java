package com.uten.imp.features.master.goods.importing;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.goods.Goods;
import com.uten.imp.features.master.goods.GoodsBomPasteService;
import com.uten.imp.features.master.goods.GoodsRepository;
import com.uten.imp.features.master.goods.dto.BomItemView;
import com.uten.imp.features.master.goods.dto.BomPasteRequest;
import com.uten.imp.features.master.goods.dto.BomPasteResult;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.io.ByteArrayOutputStream;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class GoodsBomImportMergeServiceTest {
    private final Goods parent = goods("P1"), existing = goods("C1"), added = goods("C2");
    private final GoodsRepository goods = mock(GoodsRepository.class);
    private final GoodsBomPasteService paste = mock(GoodsBomPasteService.class);
    private final GoodsBomImportService importer = new GoodsBomImportService(goods, paste);
    private final BomItemView prior = mock(BomItemView.class);

    GoodsBomImportMergeServiceTest() {
        for (Goods row : List.of(parent, existing, added)) {
            when(goods.findById(row.getId())).thenReturn(Optional.of(row));
            when(goods.findByCodeAndDeletedFalse(row.getCode())).thenReturn(Optional.of(row));
        }
        when(prior.getQty()).thenReturn(new BigDecimal("1.00000"));
        when(prior.getComponentName()).thenReturn("旧组件");
        when(prior.getConsumptionBasis()).thenReturn("PER_UNIT");
        when(prior.getBasisOutputQty()).thenReturn(BigDecimal.ONE);
        when(prior.isAllowPartialPackage()).thenReturn(true);
        when(paste.importReviewRows(anySet(), anySet()))
                .thenReturn(Map.of(parent.getId(), Map.of(existing.getId(), prior)));
        when(paste.importStateSnapshot(anySet(), anySet(), anySet())).thenReturn("baseline");
        when(paste.mergeImported(any(), anySet(), anyMap()))
                .thenReturn(new BomPasteResult(1, 1, 0, List.of(), List.of()));
    }

    @Test void detectsActualDifferencesWithOldAndNewValuesAndFillKinds() throws Exception {
        var report = detect(file(new String[]{"序号", "物料编号", "数量", "备注"}, new String[][]{{"1", "C1", "2", "补备注"}}));
        assertEquals(1, report.conflictRows());
        assertEquals(1, report.fillRows());
        var row = report.reviewRows().getFirst();
        assertEquals("BOM", row.scope());
        assertEquals(parent.getId(), row.parentGoodsId());
        assertEquals("1", row.changes().getFirst().oldValue());
        assertEquals("2", row.changes().getFirst().newValue());
        assertEquals("CONFLICT", row.changes().getFirst().kind());
        assertEquals("FILL", row.changes().getLast().kind());
    }

    @Test void reusedComponentCodesCannotBindAnOldWorkbookToANewGoodsUuid() throws Exception {
        when(goods.codeHasReuseHistory("C1")).thenReturn(true);
        var report = detect(minimal("2"));
        assertTrue(report.errors().stream().anyMatch(error -> error.column().equals("物料编号") && error.message().contains("曾复用")));
        assertNull(report.stateFingerprint());
        verify(paste, never()).mergeImported(any(), anySet(), anyMap());
    }

    @Test void exportedReusedComponentWithItsSystemUuidImportsAndTheRetiredUuidIsRejected() throws Exception {
        when(goods.codeHasReuseHistory("C1")).thenReturn(true);
        var values = Map.<String, Object>of("seq", "1", "code", "C1", "name", existing.getName(),
                "qty", BigDecimal.ONE, "componentGoodsId", existing.getId().toString());
        byte[] exported = new com.uten.imp.common.export.XlsxExportService().build(
                com.uten.imp.features.master.goods.GoodsBomService.EXPORT_COLUMNS, List.of(values));
        var current = detect(exported);
        assertTrue(current.errors().isEmpty(), current.errors().toString());
        assertNotNull(current.stateFingerprint());
        var retired = detect(file(new String[]{"序号", "物料编号", "数量", "组件系统标识"},
                new String[][]{{"1", "C1", "1", UUID.randomUUID().toString()}}));
        assertTrue(retired.errors().stream().anyMatch(error -> error.column().equals("组件系统标识") && error.message().contains("不同货品")));
        assertNull(retired.stateFingerprint());
    }

    @Test void ignoringConflictsStillFillsBlanksWithoutOverwritingQuantity() throws Exception {
        byte[] file = file(new String[]{"序号", "物料编号", "数量", "备注"}, new String[][]{{"1", "C1", "2", "补备注"}});
        var result = merge(file, Set.of());
        var request = captured();
        assertEquals(0, BigDecimal.ONE.compareTo(request.items().getFirst().getQty()));
        assertEquals("补备注", request.items().getFirst().getSummary());
        assertEquals(1, result.filledCount());
        assertEquals(0, result.updatedCount());
        assertEquals(1, result.ignoredCount());
        assertEquals(0, result.added());
        assertEquals(0, result.removed());
    }

    @Test void selectedConflictUsesImportedValues() throws Exception {
        byte[] file = minimal("2");
        var report = detect(file);
        merge(file, Set.of(report.reviewRows().getFirst().rowKey()));
        assertEquals(0, new BigDecimal("2").compareTo(captured().items().getFirst().getQty()));
    }

    @Test void allIgnoredDoesNotWriteAnyExistingEdge() throws Exception {
        var result = merge(minimal("2"), Set.of());
        verify(paste, never()).mergeImported(any(), anySet(), anyMap());
        verify(paste, never()).markImportApplied(anySet());
        assertEquals(1, result.ignoredCount());
        assertEquals(0, result.updatedCount());
    }

    @Test void blankOptionalCellsNeverClearExistingValues() throws Exception {
        when(prior.getSummary()).thenReturn("保留备注");
        when(prior.getComponentColorName()).thenReturn("蓝色");
        when(prior.getConsumptionBasis()).thenReturn("PER_PACKAGE");
        when(prior.getBasisOutputQty()).thenReturn(new BigDecimal("12"));
        when(prior.isAllowPartialPackage()).thenReturn(false);
        byte[] file = file(new String[]{"序号", "物料编号", "数量", "颜色", "备注", "计量方式", "基准产量", "尾包"},
                new String[][]{{"1", "C1", "2", "", "", "", "", ""}});
        var report = detect(file);
        assertEquals(1, report.reviewRows().getFirst().changes().size());
        merge(file, Set.of(report.reviewRows().getFirst().rowKey()));
        var item = captured().items().getFirst();
        assertEquals("保留备注", item.getSummary());
        assertEquals("PER_PACKAGE", item.getConsumptionBasis());
        assertEquals(new BigDecimal("12"), item.getBasisOutputQty());
        assertEquals(false, item.getAllowPartialPackage());
        verify(paste).mergeImported(any(), anySet(), eq(Map.of()));
    }

    @Test void numericScaleAndReadOnlyCustomerColumnsDoNotCreateDifferences() throws Exception {
        byte[] file = file(new String[]{"序号", "物料编号", "数量", "客户型号", "客户货品名称", "真实使用数量"},
                new String[][]{{"1", "C1", "1.0", "不写入主档", "不写入主档", "999"}});
        var report = detect(file);
        assertEquals(0, report.reviewRows().size());
        assertEquals(1, report.unchangedRows());
        assertEquals(1, merge(file, Set.of()).unchangedCount());
        verify(paste, never()).mergeImported(any(), anySet(), anyMap());
    }

    @Test void ignoringExistingConflictStillImportsNewComponents() throws Exception {
        byte[] file = file(new String[]{"序号", "物料编号", "数量"}, new String[][]{{"1", "C1", "2"}, {"2", "C2", "3"}});
        assertEquals(1, detect(file).addedRows());
        var result = merge(file, Set.of());
        assertEquals(1, result.added());
        assertEquals(added.getId(), captured().items().getFirst().getComponentGoodsId());
        assertEquals(1, captured().items().size());
    }

    @Test void unrelatedOrFillOnlySelectionsAreRejectedBeforeWriting() throws Exception {
        byte[] file = minimal("2");
        assertThrows(ApiException.class, () -> merge(file, Set.of("bom:foreign")));
        verify(paste, never()).mergeImported(any(), anySet(), anyMap());
    }

    @Test void duplicateComponentsUnderOneParentAreAmbiguousAndNeverMerged() throws Exception {
        byte[] file = file(new String[]{"序号", "物料编号", "数量"}, new String[][]{{"1", "C1", "2"}, {"2", "C1", "3"}});
        assertTrue(detect(file).errors().stream().anyMatch(error -> error.message().contains("重复")));
        assertThrows(ApiException.class, () -> importer.commitMerged(parent.getId(), file, "v1:any", Set.of()));
        verify(paste, never()).mergeImported(any(), anySet(), anyMap());
    }

    @Test void duplicateAliasHeadersAreRejectedInsteadOfSilentlyPickingAColumn() throws Exception {
        byte[] file = file(new String[]{"序号", "物料编号", "数量", "设计使用数量"}, new String[][]{{"1", "C1", "2", "3"}});
        assertTrue(detect(file).errors().stream().anyMatch(error -> error.message().contains("重复")));
    }

    @Test void changedFileOrConcurrentStateCannotUseAnOldReview() throws Exception {
        byte[] file = minimal("2");
        String token = detect(file).stateFingerprint();
        assertThrows(ApiException.class, () -> importer.commitMerged(parent.getId(), minimal("3"), token, Set.of()));
        when(paste.importStateSnapshot(anySet(), anySet(), anySet())).thenReturn("new-learning-or-master-state");
        assertThrows(ApiException.class, () -> importer.commitMerged(parent.getId(), file, token, Set.of()));
        verify(paste, never()).mergeImported(any(), anySet(), anyMap());
    }

    @Test void equivalentPeriodicBatchRepresentationHasNoFalseQuantityConflict() throws Exception {
        existing.setIssueMethod("PERIODIC");
        existing.setPeriodicCostBasis("OWN");
        byte[] file = file(new String[]{"序号", "物料编号", "数量", "基准产量"}, new String[][]{{"1", "C1", "10", "10"}});
        assertTrue(detect(file).reviewRows().isEmpty());
        merge(file, Set.of());
        verify(paste, never()).mergeImported(any(), anySet(), anyMap());
    }

    private BomImportReport detect(byte[] file) { return importer.detect(parent.getId(), file); }
    private BomImportResult merge(byte[] file, Set<String> selected) {
        return importer.commitMerged(parent.getId(), file, detect(file).stateFingerprint(), selected);
    }
    private BomPasteRequest captured() {
        var captured = ArgumentCaptor.forClass(BomPasteRequest.class);
        verify(paste).mergeImported(captured.capture(), anySet(), anyMap());
        return captured.getValue();
    }
    private static Goods goods(String code) { var goods = new Goods(); goods.setCode(code); goods.setName(code); return goods; }
    private static byte[] minimal(String qty) throws Exception {
        return file(new String[]{"序号", "物料编号", "数量"}, new String[][]{{"1", "C1", qty}});
    }
    private static byte[] file(String[] headers, String[][] rows) throws Exception {
        try (var workbook = new XSSFWorkbook(); var output = new ByteArrayOutputStream()) {
            var sheet = workbook.createSheet(); var header = sheet.createRow(0);
            for (int i = 0; i < headers.length; i++) header.createCell(i).setCellValue(headers[i]);
            for (int i = 0; i < rows.length; i++) {
                var row = sheet.createRow(i + 1);
                for (int j = 0; j < rows[i].length; j++) row.createCell(j).setCellValue(rows[i][j]);
            }
            workbook.write(output); return output.toByteArray();
        }
    }
}
