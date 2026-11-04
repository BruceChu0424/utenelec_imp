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
import jakarta.persistence.TypedQuery;
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
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;

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
        @SuppressWarnings("unchecked")
        TypedQuery<java.util.UUID> bomQuery = mock(TypedQuery.class);
        when(bomQuery.setParameter(anyString(), any())).thenReturn(bomQuery);
        when(bomQuery.getResultList()).thenReturn(List.of());
        when(em.createQuery(anyString(), eq(java.util.UUID.class))).thenReturn(bomQuery);
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

    @Test void resolvedUuidReferencesDoNotReadUnusedLegacyNames() {
        Goods goods=canonical(101,202,303,"现代蓝","现代件","MODERN-M");
        returnPage(goods);
        var item=service.list(emptyFilter(),1,20,null,null).getItems().getFirst();
        assertEquals("现代蓝",item.getColorName());assertEquals("现代件",item.getUnitName());
        assertEquals("MODERN-M",item.getMouldCode());
        verifyNoInteractions(colorRepo,unitRepo,mouldRepo);
    }

    @Test void mixedPagesReadOnlyTheLegacyIdsWhoseUuidRelationshipIsMissing() {
        Goods resolved=canonical(101,202,303,"现代蓝","现代件","MODERN-M");
        Goods historical=new Goods();historical.setColorLegacyId(102);historical.setUnitLegacyId(203);historical.setMouldLegacyId(304);
        Color oldColor=new Color();oldColor.setLegacyId(102);oldColor.setName("历史白");
        Unit oldUnit=new Unit();oldUnit.setLegacyId(203);oldUnit.setName("历史箱");
        Mould oldMould=new Mould();oldMould.setLegacyId(304);oldMould.setCode("LEGACY-M");
        when(colorRepo.findByLegacyIdInAndDeletedFalse(Set.of(102))).thenReturn(List.of(oldColor));
        when(unitRepo.findByLegacyIdInAndDeletedFalse(Set.of(203))).thenReturn(List.of(oldUnit));
        when(mouldRepo.findByLegacyIdInAndDeletedFalse(Set.of(304))).thenReturn(List.of(oldMould));
        returnPage(resolved,historical);
        var items=service.list(emptyFilter(),1,20,null,null).getItems();
        assertEquals(List.of("现代蓝","历史白"),items.stream().map(item->item.getColorName()).toList());
        assertEquals(List.of("现代件","历史箱"),items.stream().map(item->item.getUnitName()).toList());
        assertEquals(List.of("MODERN-M","LEGACY-M"),items.stream().map(item->item.getMouldCode()).toList());
        verify(colorRepo).findByLegacyIdInAndDeletedFalse(Set.of(102));
        verify(unitRepo).findByLegacyIdInAndDeletedFalse(Set.of(203));
        verify(mouldRepo).findByLegacyIdInAndDeletedFalse(Set.of(304));
    }

    @Test void deletedOrNamelessCanonicalReferencesNeverResurrectFromLegacyShadows() {
        Goods deleted=canonical(101,202,303,"已删颜色","已删单位","DELETED-M");
        deleted.getColor().setDeleted(true);deleted.getUnit().setDeleted(true);deleted.getMould().setDeleted(true);
        Goods nameless=canonical(102,203,304,null,null,null);nameless.getMould().setName("真实空编号模具");
        returnPage(deleted,nameless);
        var items=service.list(emptyFilter(),1,20,null,null).getItems();
        for(var item:items){assertNull(item.getColorName());assertNull(item.getUnitName());assertNull(item.getMouldCode());}
        assertEquals("真实空编号模具",items.get(1).getMouldName());
        assertEquals(nameless.getColor().getId(),items.get(1).getColorId());
        verifyNoInteractions(colorRepo,unitRepo,mouldRepo);
    }

    private Goods canonical(int colorLegacy,int unitLegacy,int mouldLegacy,String colorName,String unitName,String mouldCode) {
        Goods goods=new Goods();goods.setColorLegacyId(colorLegacy);goods.setUnitLegacyId(unitLegacy);goods.setMouldLegacyId(mouldLegacy);
        Color color=new Color();color.setLegacyId(colorLegacy);color.setName(colorName);goods.setColor(color);
        Unit unit=new Unit();unit.setLegacyId(unitLegacy);unit.setName(unitName);goods.setUnit(unit);
        Mould mould=new Mould();mould.setLegacyId(mouldLegacy);mould.setCode(mouldCode);goods.setMould(mould);
        return goods;
    }

    private void returnPage(Goods... goods) {
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
                null, null, null, null, null, null, null, null, null);
    }
}
