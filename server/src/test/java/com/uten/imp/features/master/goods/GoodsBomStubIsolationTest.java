package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.BomItemSaveRequest;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class GoodsBomStubIsolationTest {

    private final GoodsRepository goodsRepo = mock(GoodsRepository.class);
    private final GoodsBomItemRepository bomRepo = mock(GoodsBomItemRepository.class);
    private final ColorRepository colorRepo = mock(ColorRepository.class);
    private final UnitRepository unitRepo = mock(UnitRepository.class);
    private final TxSessionVars tx = mock(TxSessionVars.class);
    private final MasterReferenceValidationPort references = mock(MasterReferenceValidationPort.class);
    private final GoodsMasterRelationshipResolver relationships = mock(GoodsMasterRelationshipResolver.class);
    private final GoodsBomService service = new GoodsBomService(
            goodsRepo, bomRepo, colorRepo, unitRepo, tx, references, relationships,
            mock(com.uten.imp.application.port.BusinessEventPublisher.class));

    @Test
    void listHidesLegacyStubComponentsEvenBeforeDatabaseCleanup() {
        Goods parent = goods("P-1", false);
        Goods stub = goods(null, true);
        GoodsBomItem migratedOrphan = new GoodsBomItem();
        migratedOrphan.setGoods(parent);
        migratedOrphan.setComponent(stub);

        when(goodsRepo.findById(parent.getId())).thenReturn(Optional.of(parent));
        when(bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(parent.getId()))
                .thenReturn(List.of(migratedOrphan));

        assertTrue(service.list(parent.getId()).isEmpty());
    }

    @Test
    void createRejectsLegacyStubComponentWhenApiBypassesPicker() {
        Goods parent = goods("P-1", false);
        Goods stub = goods(null, true);
        BomItemSaveRequest request = new BomItemSaveRequest();
        request.setComponentGoodsId(stub.getId());
        request.setQty(BigDecimal.ONE);

        when(goodsRepo.findById(parent.getId())).thenReturn(Optional.of(parent));
        when(goodsRepo.findById(stub.getId())).thenReturn(Optional.of(stub));

        ApiException error = assertThrows(ApiException.class,
                () -> service.create(parent.getId(), request));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        assertEquals("迁移占位货品只用于历史引用，不能加入当前组装清单", error.getMessage());
        verify(bomRepo, never()).save(any());
    }

    @Test
    void listRejectsLegacyStubAsBomParent() {
        Goods stubParent = goods(null, true);
        when(goodsRepo.findById(stubParent.getId())).thenReturn(Optional.of(stubParent));

        ApiException error = assertThrows(ApiException.class,
                () -> service.list(stubParent.getId()));

        assertEquals(ErrorCode.NOT_FOUND, error.getCode());
        verify(bomRepo, never())
                .findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(stubParent.getId());
    }

    @Test
    void listRedactsInvisibleComponentButKeepsRelationDeletable() {
        Goods parent = goods("P-1", false);
        Goods secret = goods("SECRET-1", false);
        GoodsBomItem row = bomRow(parent, secret);
        row.setQty(new BigDecimal("2"));
        when(goodsRepo.findById(parent.getId())).thenReturn(Optional.of(parent));
        when(bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(parent.getId()))
                .thenReturn(List.of(row));
        when(references.canViewGoods(secret.getId())).thenReturn(false);

        var view = service.list(parent.getId()).getFirst();

        assertEquals(row.getId(), view.getId());
        assertEquals(secret.getId(), view.getComponentGoodsId());
        assertEquals(new BigDecimal("2"), view.getQty());
        assertNull(view.getComponentCode());
        assertNull(view.getComponentName());
        assertNull(view.getComponentModel());
        assertNull(view.getComponentSpec());
        assertNull(view.getComponentMaterial());
        assertNull(view.getComponentUnitName());
        assertNull(view.getComponentColorName());
        assertNull(view.getColorId());
        assertNull(view.getColorLegacyId());
        assertNull(view.getDefaultSupplierId());
        assertNull(view.getVendLegacyId());
        assertNull(view.getComponentSourceType());
        verify(references).requireVisibleGoods(parent.getId());
        verify(references, never()).requireVisibleActiveGoods(secret.getId());
    }

    @Test
    void deleteAllowsCleanupOfInactiveComponent() {
        Goods parent = goods("P-1", false);
        Goods inactive = goods("OLD-1", false);
        inactive.setStatus("禁用");
        GoodsBomItem row = bomRow(parent, inactive);
        when(bomRepo.findById(row.getId())).thenReturn(Optional.of(row));
        when(bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(parent.getId()))
                .thenReturn(List.of());

        service.delete(parent.getId(), row.getId());

        assertTrue(row.isDeleted());
        verify(references).requireVisibleGoods(parent.getId());
        verify(references, never()).requireVisibleActiveGoods(inactive.getId());
        verify(bomRepo).save(row);
    }

    @Test
    void updateAllowsReplacingInactiveComponentButRequiresActiveNewTarget() {
        Goods parent = goods("P-1", false);
        Goods inactive = goods("OLD-1", false);
        inactive.setStatus("禁用");
        Goods replacement = goods("NEW-1", false);
        GoodsBomItem row = bomRow(parent, inactive);
        BomItemSaveRequest request = new BomItemSaveRequest();
        request.setComponentGoodsId(replacement.getId());
        request.setQty(BigDecimal.ONE);
        when(bomRepo.findById(row.getId())).thenReturn(Optional.of(row));
        when(goodsRepo.findById(replacement.getId())).thenReturn(Optional.of(replacement));
        when(bomRepo.findByGoods_IdAndComponent_IdAndDeletedFalse(
                parent.getId(), replacement.getId())).thenReturn(Optional.empty());
        when(bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(replacement.getId()))
                .thenReturn(List.of());
        when(bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(parent.getId()))
                .thenReturn(List.of());

        service.update(parent.getId(), row.getId(), request);

        assertEquals(replacement, row.getComponent());
        verify(references).requireVisibleGoods(parent.getId());
        verify(references).requireVisibleActiveGoods(replacement.getId());
        verify(references, never()).requireVisibleActiveGoods(inactive.getId());
    }

    private static GoodsBomItem bomRow(Goods parent, Goods component) {
        GoodsBomItem row = new GoodsBomItem();
        row.setGoods(parent);
        row.setComponent(component);
        row.setQty(BigDecimal.ONE);
        return row;
    }

    private static Goods goods(String code, boolean autoCreated) {
        Goods goods = new Goods();
        goods.setCode(code);
        goods.setName(autoCreated ? "(migration auto-stub legacy 20344)" : "真实货品");
        goods.setAutoCreated(autoCreated);
        return goods;
    }
}
