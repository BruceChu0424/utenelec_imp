package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.mastercode.CategoryCodeAllocation;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
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
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class GoodsUuidRelationshipServiceTest {

    @Test
    void uuidGoodsRequestPersistsUuidAndCanonicalLegacySnapshot() {
        GoodsRepository goodsRepo = mock(GoodsRepository.class);
        MaterialCategoryRepository categoryRepo = mock(MaterialCategoryRepository.class);
        ColorRepository colorRepo = mock(ColorRepository.class);
        UnitRepository unitRepo = mock(UnitRepository.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        CategoryDrivenCodeService codes = mock(CategoryDrivenCodeService.class);
        GoodsMasterRelationshipResolver relationships = mock(GoodsMasterRelationshipResolver.class);
        EntityManager em = stubbedEm();
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.get()).thenReturn(Optional.empty());
        GoodsCostMasker costMasker = mock(GoodsCostMasker.class);
        when(costMasker.canView()).thenReturn(true);
        GoodsService service = new GoodsService(
                goodsRepo, categoryRepo, colorRepo, unitRepo, tx,
                em, codes, mock(OwnerVisibility.class), currentUser, costMasker, relationships);

        MaterialCategory category = new MaterialCategory();
        Color color = new Color();
        color.setLegacyId(101);
        color.setName("Blue");
        Unit unit = new Unit();
        unit.setLegacyId(102);
        unit.setName("piece");
        Unit thicknessUnit = new Unit();
        thicknessUnit.setLegacyId(103);
        thicknessUnit.setName("mm");
        Unit weightUnit = new Unit();
        weightUnit.setLegacyId(104);
        weightUnit.setName("kg");
        when(categoryRepo.findById(category.getId())).thenReturn(Optional.of(category));
        when(relationships.color(color.getId())).thenReturn(color);
        when(relationships.unit(unit.getId())).thenReturn(unit);
        when(relationships.unit(thicknessUnit.getId())).thenReturn(thicknessUnit);
        when(relationships.unit(weightUnit.getId())).thenReturn(weightUnit);
        when(codes.allocate(
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.isNull()))
                .thenReturn(new CategoryCodeAllocation("HP000001", 1, null, true));

        GoodsSaveRequest request = new GoodsSaveRequest();
        request.setCategoryId(category.getId());
        request.setName("Fixture");
        request.setColorId(color.getId());
        request.setUnitId(unit.getId());
        request.setThicknessUnitId(thicknessUnit.getId());
        request.setMWeightUnitId(weightUnit.getId());

        GoodsDetail detail = service.create(request);

        ArgumentCaptor<Goods> saved = ArgumentCaptor.forClass(Goods.class);
        verify(goodsRepo).save(saved.capture());
        assertSame(color, saved.getValue().getColor());
        assertSame(unit, saved.getValue().getUnit());
        assertEquals(color.getId(), detail.getColorId());
        assertEquals(101, detail.getColorLegacyId());
        assertEquals(unit.getId(), detail.getUnitId());
        assertEquals(102, detail.getUnitLegacyId());
        assertSame(thicknessUnit, saved.getValue().getThicknessUnit());
        assertSame(weightUnit, saved.getValue().getMWeightUnit());
        assertEquals(thicknessUnit.getId(), detail.getThicknessUnitId());
        assertEquals(103, detail.getThicknessUnitLegacyId());
        assertEquals(weightUnit.getId(), detail.getMWeightUnitId());
        assertEquals(104, detail.getMWeightUnitLegacyId());
    }

    @Test
    void uuidBomRequestPersistsUuidAndCanonicalLegacySnapshot() {
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
        when(relationships.color(color.getId())).thenReturn(color);

        BomItemSaveRequest request = new BomItemSaveRequest();
        request.setComponentGoodsId(component.getId());
        request.setQty(BigDecimal.ONE);
        request.setColorId(color.getId());

        BomItemView view = service.create(parent.getId(), request);

        ArgumentCaptor<GoodsBomItem> saved = ArgumentCaptor.forClass(GoodsBomItem.class);
        verify(bomRepo).save(saved.capture());
        assertSame(color, saved.getValue().getColor());
        assertEquals(color.getId(), view.getColorId());
        assertEquals(201, view.getColorLegacyId());
    }

    /** 货品详情即时库存聚合走原生查询：mock 成空结果（本测试不关心库存，仅避免 NPE）。 */
    private static EntityManager stubbedEm() {
        EntityManager em = mock(EntityManager.class);
        Query q = mock(Query.class);
        when(q.setParameter(anyString(), any())).thenReturn(q);
        when(q.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(q);
        return em;
    }
}
