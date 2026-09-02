package com.uten.imp.features.master.goods;

import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.features.master.color.Color;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.mould.Mould;
import com.uten.imp.features.master.mould.MouldRepository;
import com.uten.imp.features.master.unit.Unit;
import com.uten.imp.features.master.unit.UnitRepository;
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
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class GoodsListMasterNameResolutionTest {

    private final GoodsRepository goodsRepo = mock(GoodsRepository.class);
    private final MaterialCategoryRepository categoryRepo = mock(MaterialCategoryRepository.class);
    private final ColorRepository colorRepo = mock(ColorRepository.class);
    private final UnitRepository unitRepo = mock(UnitRepository.class);
    private final MouldRepository mouldRepo = mock(MouldRepository.class);
    private final GoodsService service = new GoodsService(
            goodsRepo,
            categoryRepo,
            colorRepo,
            unitRepo,
            mouldRepo,
            mock(TxSessionVars.class),
            stubbedEm(),
            mock(CategoryDrivenCodeService.class),
            mock(OwnerVisibility.class),
            mock(SecurityContextCurrentUser.class),
            mock(GoodsCostMasker.class),
            mock(GoodsMasterRelationshipResolver.class));

    /** 即时库存聚合走原生查询：mock 成空结果（本测试仅关心颜色/单位名解析，不关心库存）。 */
    private static EntityManager stubbedEm() {
        EntityManager em = mock(EntityManager.class);
        Query q = mock(Query.class);
        when(q.setParameter(anyString(), any())).thenReturn(q);
        when(q.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(q);
        return em;
    }

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

    @Test
    void listResolvesMouldCodeFromLegacySnapshotWhenUuidMissing() {
        Goods goods = new Goods();
        goods.setMouldLegacyId(3482);
        Mould mould = new Mould();
        mould.setLegacyId(3482);
        mould.setCode("19-05-43-A");
        returnPage(goods);
        when(mouldRepo.findByLegacyIdInAndDeletedFalse(Set.of(3482)))
                .thenReturn(List.of(mould));

        var item = service.list(emptyFilter(), 1, 20, null, null)
                .getItems().getFirst();

        // 历史只读回显：UUID 缺失按 legacy 快照补模具编号，不建立新关系。
        assertEquals("19-05-43-A", item.getMouldCode());
    }

    @Test
    void listResolvesMouldCodeFromUuidRelationFirst() {
        Goods goods = new Goods();
        Mould mould = new Mould();
        mould.setCode("19-05-43");
        goods.setMould(mould);
        returnPage(goods);

        var item = service.list(emptyFilter(), 1, 20, null, null)
                .getItems().getFirst();

        assertEquals("19-05-43", item.getMouldCode());
    }

    @Test
    void listCarriesRearInsertCodeAndPaperThrough() {
        Goods goods = new Goods();
        goods.setRearInsertCode("45A");
        goods.setPaper("换后模45A镶件");
        returnPage(goods);

        var item = service.list(emptyFilter(), 1, 20, null, null)
                .getItems().getFirst();

        // 备注原文与解析出的后模镶件编号同时下发：列表「备注」「后模镶件编号」两列各取所需。
        assertEquals("45A", item.getRearInsertCode());
        assertEquals("换后模45A镶件", item.getPaper());
    }

    @Test
    void listTreatsDeletedMouldRelationAsUnresolved() {
        Goods goods = new Goods();
        Mould deleted = new Mould();
        deleted.setCode("19-05-43-J");
        deleted.setDeleted(true);
        goods.setMould(deleted);
        returnPage(goods);

        var item = service.list(emptyFilter(), 1, 20, null, null)
                .getItems().getFirst();

        // 软删模具不显编号（口径同颜色/单位），但关系快照不下发新 mouldId。
        assertNull(item.getMouldCode());
    }

    private void returnPage(Goods goods) {
        when(goodsRepo.findAll(
                org.mockito.ArgumentMatchers.<Specification<Goods>>any(),
                any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(goods)));
    }

    private static GoodsQueryFilter emptyFilter() {
        return new GoodsQueryFilter(
                null, null, null, Set.of(),
                null, null, null, null, null, null, null, null,
                null, null, null,
                null, null, null, null, null, null, null);
    }
}
