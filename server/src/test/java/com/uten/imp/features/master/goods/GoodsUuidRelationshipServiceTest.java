package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.features.master.color.Color;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.BomItemSaveRequest;
import com.uten.imp.features.master.goods.dto.BomItemView;
import com.uten.imp.features.master.goods.dto.GoodsDetail;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.unit.Unit;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class GoodsUuidRelationshipServiceTest {

    @Test
    void legacyOnlyGoodsRequestBackfillsUuidAndCanonicalLegacyId() {
        GoodsRepository goodsRepo = mock(GoodsRepository.class);
        MaterialCategoryRepository categoryRepo = mock(MaterialCategoryRepository.class);
        ColorRepository colorRepo = mock(ColorRepository.class);
        UnitRepository unitRepo = mock(UnitRepository.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        MasterCodeService codes = mock(MasterCodeService.class);
        GoodsMasterRelationshipResolver relationships = mock(GoodsMasterRelationshipResolver.class);
        GoodsService service = new GoodsService(
                goodsRepo, categoryRepo, colorRepo, unitRepo, tx,
                mock(EntityManager.class), codes, mock(OwnerVisibility.class), relationships);

        MaterialCategory category = new MaterialCategory();
        Color color = new Color();
        color.setLegacyId(101);
        color.setName("Blue");
        Unit unit = new Unit();
        unit.setLegacyId(102);
        unit.setName("piece");
        when(categoryRepo.findById(category.getId())).thenReturn(Optional.of(category));
        when(relationships.color(null, 101)).thenReturn(color);
        when(relationships.unit(null, 102)).thenReturn(unit);
        when(codes.nextCode(org.mockito.ArgumentMatchers.any())).thenReturn("G-1");

        GoodsSaveRequest request = new GoodsSaveRequest();
        request.setCategoryId(category.getId());
        request.setName("Fixture");
        request.setColorLegacyId(101);
        request.setUnitLegacyId(102);

        GoodsDetail detail = service.create(request);

        ArgumentCaptor<Goods> saved = ArgumentCaptor.forClass(Goods.class);
        verify(goodsRepo).save(saved.capture());
        assertSame(color, saved.getValue().getColor());
        assertSame(unit, saved.getValue().getUnit());
        assertEquals(color.getId(), detail.getColorId());
        assertEquals(101, detail.getColorLegacyId());
        assertEquals(unit.getId(), detail.getUnitId());
        assertEquals(102, detail.getUnitLegacyId());
    }

    @Test
    void legacyOnlyBomRequestBackfillsUuidWithoutTouchingOperationalGuards() {
        GoodsRepository goodsRepo = mock(GoodsRepository.class);
        GoodsBomItemRepository bomRepo = mock(GoodsBomItemRepository.class);
        GoodsMasterRelationshipResolver relationships = mock(GoodsMasterRelationshipResolver.class);
        GoodsBomService service = new GoodsBomService(
                goodsRepo, bomRepo, mock(ColorRepository.class), mock(UnitRepository.class),
                mock(TxSessionVars.class), mock(MasterReferenceValidationPort.class), relationships,
                mock(com.uten.imp.application.port.BusinessEventPublisher.class));

        Goods parent = new Goods();
        parent.setName("Parent");
        Goods component = new Goods();
        component.setName("Component");
        Color color = new Color();
        color.setLegacyId(201);
        color.setName("Red");
        when(goodsRepo.findById(parent.getId())).thenReturn(Optional.of(parent));
        when(goodsRepo.findById(component.getId())).thenReturn(Optional.of(component));
        when(bomRepo.findByGoods_IdAndComponent_IdAndDeletedFalse(
                parent.getId(), component.getId())).thenReturn(Optional.empty());
        when(relationships.color(null, 201)).thenReturn(color);

        BomItemSaveRequest request = new BomItemSaveRequest();
        request.setComponentGoodsId(component.getId());
        request.setQty(BigDecimal.ONE);
        request.setColorLegacyId(201);

        BomItemView view = service.create(parent.getId(), request);

        ArgumentCaptor<GoodsBomItem> saved = ArgumentCaptor.forClass(GoodsBomItem.class);
        verify(bomRepo).save(saved.capture());
        assertSame(color, saved.getValue().getColor());
        assertEquals(color.getId(), view.getColorId());
        assertEquals(201, view.getColorLegacyId());
    }
}
