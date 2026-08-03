package com.uten.imp.features.master.goods;

import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.features.master.color.Color;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.unit.Unit;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.util.List;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class GoodsListMasterNameResolutionTest {

    private final GoodsRepository goodsRepo = mock(GoodsRepository.class);
    private final MaterialCategoryRepository categoryRepo = mock(MaterialCategoryRepository.class);
    private final ColorRepository colorRepo = mock(ColorRepository.class);
    private final UnitRepository unitRepo = mock(UnitRepository.class);
    private final GoodsService service = new GoodsService(
            goodsRepo,
            categoryRepo,
            colorRepo,
            unitRepo,
            mock(TxSessionVars.class),
            mock(EntityManager.class),
            mock(MasterCodeService.class),
            mock(OwnerVisibility.class),
            mock(GoodsMasterRelationshipResolver.class));

    @Test
    void listTreatsNullColorNameAsUnresolvedWithoutDroppingLegacyId() {
        Goods goods = new Goods();
        goods.setColorLegacyId(101);
        Color color = new Color();
        color.setLegacyId(101);
        returnPage(goods);
        when(colorRepo.findByLegacyIdInAndDeletedFalse(Set.of(101)))
                .thenReturn(List.of(color));

        var item = service.list(emptyFilter(), 1, 20, null, null)
                .getItems().getFirst();

        assertEquals(101, item.getColorLegacyId());
        assertNull(item.getColorName());
    }

    @Test
    void listTreatsNullUnitNameAsUnresolvedWithoutDroppingLegacyId() {
        Goods goods = new Goods();
        goods.setUnitLegacyId(202);
        Unit unit = new Unit();
        unit.setLegacyId(202);
        returnPage(goods);
        when(unitRepo.findByLegacyIdInAndDeletedFalse(Set.of(202)))
                .thenReturn(List.of(unit));

        var item = service.list(emptyFilter(), 1, 20, null, null)
                .getItems().getFirst();

        assertEquals(202, item.getUnitLegacyId());
        assertNull(item.getUnitName());
    }

    private void returnPage(Goods goods) {
        when(goodsRepo.findAll(
                org.mockito.ArgumentMatchers.<Specification<Goods>>any(),
                any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(goods)));
    }

    private static GoodsQueryFilter emptyFilter() {
        return new GoodsQueryFilter(
                null, null, Set.of(),
                null, null, null, null, null, null, null, null,
                null, null, null, null, null, null, null);
    }
}
