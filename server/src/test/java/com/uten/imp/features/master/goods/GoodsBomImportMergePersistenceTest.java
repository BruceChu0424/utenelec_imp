package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.color.Color;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.importing.GoodsBomImportService;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Exercises the real importer, BOM writer and export mapping together; persistence is observable in memory. */
class GoodsBomImportMergePersistenceTest {
    private final GoodsRepository goods = mock(GoodsRepository.class);
    private final GoodsBomItemRepository items = mock(GoodsBomItemRepository.class);
    private final EntityManager em = mock(EntityManager.class);
    private final Query nativeQuery = mock(Query.class);
    private final MasterObjectAccess access = mock(MasterObjectAccess.class);
    private final GoodsBomService bom = new GoodsBomService(goods, items, mock(ColorRepository.class),
            mock(UnitRepository.class), mock(TxSessionVars.class), mock(SecurityContextCurrentUser.class),
            mock(MasterReferenceValidationPort.class), mock(GoodsMasterRelationshipResolver.class),
            mock(BusinessEventPublisher.class), access);
    private final GoodsBomPasteService paste = new GoodsBomPasteService(bom, goods, items,
            mock(MasterReferenceValidationPort.class), access, mock(TxSessionVars.class), em);
    private final GoodsBomImportService importer = new GoodsBomImportService(goods, paste);
    private final Goods parent = goods("P1"), kept = goods("C1"), omitted = goods("C2"), added = goods("C3");
    private final GoodsBomItem keptRow = edge(kept, "1", 4), omittedRow = edge(omitted, "2", 8);
    private final List<GoodsBomItem> stored = new ArrayList<>(List.of(keptRow, omittedRow));

    @BeforeEach void fixture() {
        auth("goods:bom:create", "goods:bom:edit");
        when(access.visibleGoodsOwner()).thenReturn(owner -> true);
        for (Goods row : List.of(parent, kept, omitted, added)) {
            when(goods.findById(row.getId())).thenReturn(Optional.of(row));
            when(goods.findByCodeAndDeletedFalse(row.getCode())).thenReturn(Optional.of(row));
        }
        when(goods.findAllById(anyCollection())).thenAnswer(call -> {
            Collection<?> ids = call.getArgument(0);
            return List.of(parent, kept, omitted, added).stream().filter(row -> ids.contains(row.getId())).toList();
        });
        when(items.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(any())).thenAnswer(call ->
                stored.stream().filter(row -> row.getGoods().getId().equals(call.getArgument(0)) && !row.isDeleted()).toList());
        when(items.findAllById(anyCollection())).thenAnswer(call -> {
            Collection<?> ids = call.getArgument(0);
            return stored.stream().filter(row -> ids.contains(row.getId())).toList();
        });
        when(items.findOperationalEdges(anyCollection())).thenAnswer(call -> {
            Collection<?> ids = call.getArgument(0);
            return stored.stream().filter(row -> ids.contains(row.getGoods().getId()) && !row.isDeleted())
                    .map(row -> new Object[]{row.getId(), row.getGoods().getId(), row.getComponent().getId(), row.getSortOrder()}).toList();
        });
        when(items.materialCost(any())).thenReturn(BigDecimal.ZERO);
        when(em.createNativeQuery(anyString())).thenReturn(nativeQuery);
        when(nativeQuery.setParameter(anyString(), any())).thenReturn(nativeQuery);
        when(nativeQuery.getSingleResult()).thenReturn("snapshot");
        doAnswer(call -> { stored.add(call.getArgument(0)); return null; }).when(em).persist(any(GoodsBomItem.class));
        keptRow.setLearningProfileGoodsId(parent.getId());
        keptRow.setAuditedAt(OffsetDateTime.now());
        keptRow.setAuditedBy(UUID.randomUUID());
    }

    @AfterEach void clearAuth() { SecurityContextHolder.clearContext(); }

    @Test void originalExportMergedBackKeepsUuidLearningAuditAndParentVersionUntouched() {
        UUID id = keptRow.getId(), actor = keptRow.getAuditedBy();
        OffsetDateTime audit = keptRow.getAuditedAt();
        var payload = bom.exportPayload(parent.getId());
        byte[] workbook = new XlsxExportService().build(payload.columns(), payload.rows());
        var report = importer.detect(parent.getId(), workbook);
        assertEquals(2, report.unchangedRows());
        assertTrue(report.reviewRows().isEmpty());
        var result = importer.commitMerged(parent.getId(), workbook, report.stateFingerprint(), Set.of());
        assertEquals(0, result.added());
        assertEquals(0, result.updatedCount());
        assertEquals(id, keptRow.getId());
        assertEquals(parent.getId(), keptRow.getLearningProfileGoodsId());
        assertEquals(actor, keptRow.getAuditedBy());
        assertEquals(audit, keptRow.getAuditedAt());
        verify(em, never()).persist(any());
        verify(em, never()).lock(any(), any());
        verify(nativeQuery, never()).executeUpdate();
    }

    @Test void ignoringConflictDoesNotChangeEdgeAuditLearningOrMissingSibling() {
        UUID id = keptRow.getId(); OffsetDateTime audit = keptRow.getAuditedAt();
        var result = merge(file("5", ""), Set.of());
        assertEquals(1, result.ignoredCount());
        assertEquals(BigDecimal.ONE, keptRow.getQty());
        assertEquals(id, keptRow.getId());
        assertEquals(audit, keptRow.getAuditedAt());
        assertEquals(parent.getId(), keptRow.getLearningProfileGoodsId());
        assertFalse(omittedRow.isDeleted());
        assertEquals(8, omittedRow.getSortOrder());
        verify(em, never()).persist(any());
        verify(em, never()).lock(any(), any());
        verify(nativeQuery, never()).executeUpdate();
    }

    @Test void fillingBlankPreservesQuantityColorControlsAndOmittedSibling() {
        Color blue = new Color(); blue.setName("蓝色"); keptRow.setColor(blue);
        keptRow.setControlStage("FINISH"); keptRow.setHardGate(false);
        keptRow.setPrice(new BigDecimal("1.234567")); keptRow.setTotal(new BigDecimal("1.234567"));
        UUID id = keptRow.getId();
        var result = merge(file("5", "补齐备注"), Set.of());
        assertEquals(1, result.filledCount());
        assertEquals(0, result.updatedCount());
        assertEquals(BigDecimal.ONE, keptRow.getQty());
        assertEquals("补齐备注", keptRow.getSummary());
        assertSame(blue, keptRow.getColor());
        assertEquals("FINISH", keptRow.getControlStage());
        assertFalse(keptRow.isHardGate());
        assertEquals(new BigDecimal("1.234567"), keptRow.getTotal());
        assertEquals(id, keptRow.getId());
        assertEquals(4, keptRow.getSortOrder());
        assertFalse(omittedRow.isDeleted());
        verify(nativeQuery, never()).executeUpdate();
    }

    @Test void selectedReplacementChangesOnlyImportedEdgeAndRetainsItsUuidAndSort() {
        byte[] workbook = file("5", "");
        var report = importer.detect(parent.getId(), workbook);
        UUID id = keptRow.getId();
        var result = importer.commitMerged(parent.getId(), workbook, report.stateFingerprint(),
                Set.of(report.reviewRows().getFirst().rowKey()));
        assertEquals(1, result.updatedCount());
        assertEquals(0, result.removed());
        assertEquals(0, new BigDecimal("5").compareTo(keptRow.getQty()));
        assertEquals(id, keptRow.getId());
        assertEquals(4, keptRow.getSortOrder());
        assertNull(keptRow.getAuditedAt());
        assertFalse(omittedRow.isDeleted());
        assertEquals(new BigDecimal("2"), omittedRow.getQty());
        verify(nativeQuery, never()).executeUpdate();
    }

    @Test void createPermissionAloneCannotModifyAnExistingEdge() {
        auth("goods:bom:create");
        byte[] workbook = file("5", ""); var report = importer.detect(parent.getId(), workbook);
        var error = assertThrows(ApiException.class, () -> importer.commitMerged(parent.getId(), workbook,
                report.stateFingerprint(), Set.of(report.reviewRows().getFirst().rowKey())));
        assertEquals(ErrorCode.FORBIDDEN, error.getCode());
        assertEquals(BigDecimal.ONE, keptRow.getQty());
        verify(nativeQuery, never()).executeUpdate();
    }

    private com.uten.imp.features.master.goods.importing.BomImportResult merge(byte[] workbook, Set<String> selected) {
        return importer.commitMerged(parent.getId(), workbook, importer.detect(parent.getId(), workbook).stateFingerprint(), selected);
    }
    private byte[] file(String qty, String summary) {
        return new XlsxExportService().build(List.of(new ExportColumn("seq", "序号", ExportColumn.TEXT),
                        new ExportColumn("code", "物料编号", ExportColumn.TEXT), new ExportColumn("qty", "数量", ExportColumn.QTY),
                        new ExportColumn("summary", "备注", ExportColumn.TEXT)),
                List.of(Map.of("seq", "1", "code", "C1", "qty", new BigDecimal(qty), "summary", summary)));
    }
    private GoodsBomItem edge(Goods component, String qty, int sort) {
        var row = new GoodsBomItem(); row.setGoods(parent); row.setComponent(component);
        row.setQty(new BigDecimal(qty)); row.setSortOrder(sort); return row;
    }
    private static Goods goods(String code) { var goods = new Goods(); goods.setCode(code); goods.setName(code); return goods; }
    private static void auth(String... permissions) {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("tester", null,
                java.util.Arrays.stream(permissions).map(SimpleGrantedAuthority::new).toList()));
    }
}
