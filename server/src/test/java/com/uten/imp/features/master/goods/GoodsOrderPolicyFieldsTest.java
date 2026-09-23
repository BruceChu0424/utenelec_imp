package com.uten.imp.features.master.goods;

import com.uten.imp.common.mastercode.CategoryCodeAllocation;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.GoodsDetail;
import com.uten.imp.features.master.goods.dto.GoodsListItem;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 货品采购批量口径（V575：最小起订量 / 订货倍数）的字段往返。
 *
 * <p>口径要点：两列都是**软约束**，服务端不拦下达数量，只负责把数字存住和发出去。
 * 起订量 0 是有效登记（「问过供应商，没有起订量」），必须原样落库；订货倍数 0
 * 归一成 NULL（要参与「向上取整到倍数」的除法，0 无意义且会除零）。
 */
class GoodsOrderPolicyFieldsTest {

    private static final BigDecimal MOQ = new BigDecimal("500.0000");
    private static final BigDecimal MULTIPLE = new BigDecimal("50.0000");

    private final GoodsRepository goodsRepo = mock(GoodsRepository.class);
    private final MaterialCategoryRepository categoryRepo = mock(MaterialCategoryRepository.class);
    private final SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);

    @AfterEach
    void clearSecurityContext() {
        SecurityContextHolder.clearContext();
    }

    // ---- 写侧：请求 -> 实体 ----

    @Test
    void updatePersistsBothOrderPolicyQuantities() {
        GoodsService service = editorService();
        Goods goods = goods();
        when(goodsRepo.findById(goods.getId())).thenReturn(Optional.of(goods));
        when(goodsRepo.save(any(Goods.class))).thenAnswer(inv -> inv.getArgument(0));

        GoodsSaveRequest req = saveRequest();
        req.setMinOrderQty(MOQ);
        req.setOrderMultipleQty(MULTIPLE);

        GoodsDetail detail = service.update(goods.getId(), req);

        ArgumentCaptor<Goods> captor = ArgumentCaptor.forClass(Goods.class);
        verify(goodsRepo).save(captor.capture());
        assertEquals(MOQ, captor.getValue().getMinOrderQty());
        assertEquals(MULTIPLE, captor.getValue().getOrderMultipleQty());
        // 详情响应同口径回显（编辑页保存后立刻看到）。
        assertEquals(MOQ, detail.getMinOrderQty());
        assertEquals(MULTIPLE, detail.getOrderMultipleQty());
    }

    @Test
    void zeroMinOrderQtyIsAConfirmedFactAndSurvivesAsZero() {
        // 0 ≠ NULL：0 是「问过供应商，确认无起订量」，采购看到就不用再问。
        GoodsService service = editorService();
        Goods goods = goods();
        when(goodsRepo.findById(goods.getId())).thenReturn(Optional.of(goods));
        when(goodsRepo.save(any(Goods.class))).thenAnswer(inv -> inv.getArgument(0));

        GoodsSaveRequest req = saveRequest();
        req.setMinOrderQty(BigDecimal.ZERO);

        service.update(goods.getId(), req);

        ArgumentCaptor<Goods> captor = ArgumentCaptor.forClass(Goods.class);
        verify(goodsRepo).save(captor.capture());
        assertEquals(0, BigDecimal.ZERO.compareTo(captor.getValue().getMinOrderQty()),
                "起订量 0 必须原样落库，不能被当成未填清成 NULL");
    }

    @Test
    void zeroOrderMultipleIsNormalizedToNullBecauseRoundingUpWouldDivideByIt() {
        GoodsService service = editorService();
        Goods goods = goods();
        goods.setOrderMultipleQty(MULTIPLE);
        when(goodsRepo.findById(goods.getId())).thenReturn(Optional.of(goods));
        when(goodsRepo.save(any(Goods.class))).thenAnswer(inv -> inv.getArgument(0));

        GoodsSaveRequest req = saveRequest();
        req.setOrderMultipleQty(BigDecimal.ZERO);

        service.update(goods.getId(), req);

        ArgumentCaptor<Goods> captor = ArgumentCaptor.forClass(Goods.class);
        verify(goodsRepo).save(captor.capture());
        assertNull(captor.getValue().getOrderMultipleQty(),
                "倍数 0 视同未设：它是除数，0 会让「向上取整到倍数」除零");
    }

    @Test
    void omittingBothQuantitiesClearsThemBecauseTheFormAlwaysPostsEveryField() {
        // 编辑表单全量回传：留空 = 清掉供应商批量要求，按净需求原样下达。
        GoodsService service = editorService();
        Goods goods = goods();
        goods.setMinOrderQty(MOQ);
        goods.setOrderMultipleQty(MULTIPLE);
        when(goodsRepo.findById(goods.getId())).thenReturn(Optional.of(goods));
        when(goodsRepo.save(any(Goods.class))).thenAnswer(inv -> inv.getArgument(0));

        service.update(goods.getId(), saveRequest());

        ArgumentCaptor<Goods> captor = ArgumentCaptor.forClass(Goods.class);
        verify(goodsRepo).save(captor.capture());
        assertNull(captor.getValue().getMinOrderQty());
        assertNull(captor.getValue().getOrderMultipleQty());
    }

    // ---- 读侧：实体 -> 详情 / 列表 ----

    @Test
    void detailExposesBothQuantitiesWithoutAnyExtraPermission() {
        // 不新增权限码：持 goods:view 即可见（供应商批量要求不是成本/价格敏感项）。
        GoodsService service = serviceWith(Set.of("goods:view"));
        Goods goods = goods();
        goods.setMinOrderQty(MOQ);
        goods.setOrderMultipleQty(MULTIPLE);
        when(goodsRepo.findById(goods.getId())).thenReturn(Optional.of(goods));

        GoodsDetail detail = service.detail(goods.getId());

        assertEquals(MOQ, detail.getMinOrderQty());
        assertEquals(MULTIPLE, detail.getOrderMultipleQty());
    }

    @Test
    void listProjectionCarriesBothQuantitiesForExport() {
        GoodsService service = serviceWith(Set.of("goods:view"));
        Goods goods = goods();
        goods.setMinOrderQty(MOQ);
        goods.setOrderMultipleQty(MULTIPLE);
        when(goodsRepo.findAll(
                org.mockito.ArgumentMatchers.<Specification<Goods>>any(),
                any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(goods)));

        GoodsListItem item = service.list(emptyFilter(), 1, 20, null, null).getItems().getFirst();

        assertEquals(MOQ, item.getMinOrderQty());
        assertEquals(MULTIPLE, item.getOrderMultipleQty());
    }

    // ---- fixtures ----

    private GoodsService editorService() {
        return serviceWith(Set.of("goods:view", "goods:edit"));
    }

    private GoodsService serviceWith(Set<String> permissions) {
        SecurityContextHolder.getContext().setAuthentication(
                new TestingAuthenticationToken("test", "n/a", permissions.toArray(String[]::new)));
        when(currentUser.get()).thenReturn(Optional.of(new AuthUser(
                UUID.randomUUID(), UUID.randomUUID(), "tester", permissions, false, true, false)));
        CategoryDrivenCodeService categoryCodes = mock(CategoryDrivenCodeService.class);
        when(categoryCodes.allocateForUpdate(any(), any(), any(), any(), any()))
                .thenAnswer(invocation -> invocation.getArgument(4, CategoryCodeAllocation.class));
        GoodsCostMasker costMasker = mock(GoodsCostMasker.class);
        when(costMasker.canView()).thenReturn(false);
        return new GoodsService(
                goodsRepo,
                categoryRepo,
                mock(ColorRepository.class),
                mock(UnitRepository.class),
                mock(com.uten.imp.features.master.mould.MouldRepository.class),
                mock(TxSessionVars.class),
                stubbedEm(),
                categoryCodes,
                mock(OwnerVisibility.class),
                currentUser,
                costMasker,
                mock(GoodsMasterRelationshipResolver.class));
    }

    /** 即时库存聚合走原生查询：mock 成空结果。 */
    private static EntityManager stubbedEm() {
        EntityManager em = mock(EntityManager.class);
        Query q = mock(Query.class);
        when(q.setParameter(anyString(), any())).thenReturn(q);
        when(q.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(q);
        return em;
    }

    private static Goods goods() {
        Goods g = new Goods();
        g.setId(UUID.randomUUID());
        g.setName("原品名");
        // V258 给每条迁移/自定义（非托管）货品一个稳定正序号后才收紧 NOT NULL。
        g.setCode("LEGACY-GOODS");
        g.setCodeSequence(1L);
        g.setCodeManaged(false);
        return g;
    }

    private GoodsSaveRequest saveRequest() {
        GoodsSaveRequest req = new GoodsSaveRequest();
        MaterialCategory cat = new MaterialCategory();
        cat.setId(UUID.randomUUID());
        when(categoryRepo.findById(any(UUID.class))).thenReturn(Optional.of(cat));
        req.setCategoryId(cat.getId());
        req.setName("原品名");
        return req;
    }

    private static GoodsQueryFilter emptyFilter() {
        return new GoodsQueryFilter(
                null, null, null, Set.of(),
                null, null, null, null, null, null, null, null,
                null, null, null,
                null, null, null, null, null, null, null, null, null);
    }
}
