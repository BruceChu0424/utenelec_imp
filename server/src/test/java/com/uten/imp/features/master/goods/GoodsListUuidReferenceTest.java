package com.uten.imp.features.master.goods;

import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.features.master.color.Color;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.mould.MouldRepository;
import com.uten.imp.features.master.unit.Unit;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class GoodsListUuidReferenceTest {

    @Test
    void listReturnsColorAndUnitUuidWhenNewMastersHaveNoLegacyId() {
        UUID colorId = UUID.randomUUID();
        Color color = new Color();
        color.setId(colorId);
        color.setLegacyId(null);
        color.setName("V6 blue");

        UUID unitId = UUID.randomUUID();
        Unit unit = new Unit();
        unit.setId(unitId);
        unit.setLegacyId(null);
        unit.setName("piece");

        Goods goods = new Goods();
        goods.setId(UUID.randomUUID());
        goods.setColor(color);
        goods.setUnit(unit);

        GoodsRepository goodsRepo = mock(GoodsRepository.class);
        when(goodsRepo.findAll(
                org.mockito.ArgumentMatchers.<Specification<Goods>>any(),
                any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(goods)));

        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.get()).thenReturn(Optional.of(new AuthUser(
                UUID.randomUUID(), UUID.randomUUID(), "tester",
                Set.of(), Set.of("goods:view"), false, true, false)));

        GoodsService service = new GoodsService(
                goodsRepo,
                mock(MaterialCategoryRepository.class),
                mock(ColorRepository.class),
                mock(UnitRepository.class),
                mock(MouldRepository.class),
                mock(TxSessionVars.class),
                emptyNativeQueryEntityManager(),
                mock(CategoryDrivenCodeService.class),
                mock(OwnerVisibility.class),
                currentUser,
                mock(GoodsCostMasker.class),
                mock(GoodsMasterRelationshipResolver.class));

        var item = service.list(emptyFilter(), 1, 20, null, null).getItems().getFirst();

        assertEquals(colorId, item.getColorId());
        assertEquals(unitId, item.getUnitId());
        assertNull(item.getColorLegacyId());
        assertNull(item.getUnitLegacyId());
    }

    private static EntityManager emptyNativeQueryEntityManager() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(query);
        return em;
    }

    private static GoodsQueryFilter emptyFilter() {
        return new GoodsQueryFilter(
                null, null, null, Set.of(),
                null, null, null, null, null, null, null, null,
                null, null, null,
                null, null, null, null, null, null, null);
    }
}
