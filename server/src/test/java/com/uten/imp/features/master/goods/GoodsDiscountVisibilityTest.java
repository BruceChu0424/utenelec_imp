package com.uten.imp.features.master.goods;

import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.mastercode.CategoryCodeAllocation;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.GoodsDetail;
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
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.verify;

/**
 * 货品折扣可见性（goods:discount:view，V227）+ 写侧守卫回归。
 *
 * <p>读侧脱敏仿 goods:cost:view：未授权 detail 返 discount=null + discountMasked=true、list 返
 * discount=null。写侧：不可查看者改其他字段不得被折扣 403 误伤、折扣保留原值；可查看者+价折扣
 * 编辑权改折扣可落库（覆盖 V226 遗漏 setDiscount 的回归）。
 */
class GoodsDiscountVisibilityTest {

    private static final BigDecimal DISCOUNT = new BigDecimal("0.90");
    private static final BigDecimal PRICE = new BigDecimal("100.0000");

    private final GoodsRepository goodsRepo = mock(GoodsRepository.class);
    private final MaterialCategoryRepository categoryRepo = mock(MaterialCategoryRepository.class);
    private final SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);

    private GoodsService serviceWith(Set<String> permissions) {
        authenticate(permissions.toArray(String[]::new));
        when(currentUser.get()).thenReturn(Optional.of(new AuthUser(
                UUID.randomUUID(), UUID.randomUUID(), "tester",
                Set.of(), permissions, false, true, false)));
        CategoryDrivenCodeService categoryCodes = mock(CategoryDrivenCodeService.class);
        when(categoryCodes.allocateForUpdate(any(), any(), any(), any(), any()))
                .thenAnswer(invocation -> invocation.getArgument(4, CategoryCodeAllocation.class));
        return new GoodsService(
                goodsRepo,
                categoryRepo,
                mock(ColorRepository.class),
                mock(UnitRepository.class),
                mock(TxSessionVars.class),
                stubbedEm(),
                categoryCodes,
                mock(OwnerVisibility.class),
                currentUser,
                mock(GoodsCostMasker.class),
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

    private Goods goodsWithDiscount() {
        Goods g = new Goods();
        g.setId(UUID.randomUUID());
        g.setDiscount(DISCOUNT);
        g.setPrice(PRICE);
        g.setName("原品名");
        // V258 gives every migrated/custom (unmanaged) goods row a stable,
        // positive sequence before enforcing NOT NULL.  Keep this fixture valid
        // instead of weakening the production invariant for an impossible row.
        g.setCode("LEGACY-GOODS");
        g.setCodeSequence(1L);
        g.setCodeManaged(false);
        return g;
    }

    // ---- 读侧脱敏 ----

    @Test
    void detailMasksDiscountWhenViewerLacksPermission() {
        GoodsService service = serviceWith(Set.of("goods:view")); // 无 goods:discount:view
        Goods g = goodsWithDiscount();
        when(goodsRepo.findById(g.getId())).thenReturn(Optional.of(g));

        GoodsDetail d = service.detail(g.getId());

        assertNull(d.getDiscount());
        assertTrue(d.isDiscountMasked());
        // 价格不受折扣可见性影响，仍可见。
        assertEquals(PRICE, d.getPrice());
    }

    @Test
    void detailShowsDiscountWhenViewerHasPermission() {
        GoodsService service = serviceWith(Set.of("goods:view", "goods:discount:view"));
        Goods g = goodsWithDiscount();
        when(goodsRepo.findById(g.getId())).thenReturn(Optional.of(g));

        GoodsDetail d = service.detail(g.getId());

        assertEquals(DISCOUNT, d.getDiscount());
        assertFalse(d.isDiscountMasked());
    }

    @Test
    void listMasksDiscountWhenViewerLacksPermission() {
        GoodsService service = serviceWith(Set.of("goods:view")); // 无 goods:discount:view
        when(goodsRepo.findAll(
                org.mockito.ArgumentMatchers.<Specification<Goods>>any(),
                any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(goodsWithDiscount())));

        var item = service.list(emptyFilter(), 1, 20, null, null).getItems().getFirst();

        assertNull(item.getDiscount());
        assertEquals(PRICE, item.getPrice());
    }

    // ---- 写侧守卫 ----

    @Test
    void editorWithoutDiscountViewCanUpdateOtherFieldsWithoutBeingBlocked() {
        // 有 goods:edit、无折扣查看/价折扣编辑：改品名不得被折扣触碰判定 403。
        GoodsService service = serviceWith(Set.of("goods:view", "goods:edit"));
        Goods g = goodsWithDiscount();
        when(goodsRepo.findById(g.getId())).thenReturn(Optional.of(g));
        when(goodsRepo.save(any(Goods.class))).thenAnswer(inv -> inv.getArgument(0));

        GoodsSaveRequest req = saveRequest();
        req.setName("新品名");
        req.setPrice(PRICE);   // 售价原样回传（前端可见，未改）
        req.setDiscount(null); // 折扣隐藏不提交

        GoodsDetail d = assertDoesNotThrow(() -> service.update(g.getId(), req));

        assertEquals("新品名", d.getName());
        // 折扣对不可查看者在响应里仍脱敏，但底层须保留原值。
        assertNull(d.getDiscount());
        ArgumentCaptor<Goods> captor = ArgumentCaptor.forClass(Goods.class);
        verify(goodsRepo).save(captor.capture());
        assertEquals(DISCOUNT, captor.getValue().getDiscount(), "不可查看者保存须保留原折扣，不得被清空");
        assertEquals("新品名", captor.getValue().getName());
    }

    @Test
    void editorWithoutPriceEditCannotChangeDiscount() {
        // 可看折扣但无价折扣编辑权：改折扣 → 403。
        GoodsService service = serviceWith(Set.of("goods:view", "goods:edit", "goods:discount:view"));
        Goods g = goodsWithDiscount();
        when(goodsRepo.findById(g.getId())).thenReturn(Optional.of(g));

        GoodsSaveRequest req = saveRequest();
        req.setPrice(PRICE);
        req.setDiscount(new BigDecimal("0.80")); // 试图改折扣

        assertThrows(com.uten.imp.common.web.ApiException.class,
                () -> service.update(g.getId(), req));
    }

    @Test
    void financeCanEditDiscountAndItPersists() {
        // 可看折扣 + 价折扣编辑权：改折扣可落库（覆盖 V226 遗漏 setDiscount 的回归）。
        GoodsService service = serviceWith(
                Set.of("goods:view", "goods:edit", "goods:discount:view", "goods:price:edit"));
        Goods g = goodsWithDiscount();
        when(goodsRepo.findById(g.getId())).thenReturn(Optional.of(g));
        when(goodsRepo.save(any(Goods.class))).thenAnswer(inv -> inv.getArgument(0));

        BigDecimal newDiscount = new BigDecimal("0.85");
        GoodsSaveRequest req = saveRequest();
        req.setPrice(PRICE);
        req.setDiscount(newDiscount);

        GoodsDetail d = service.update(g.getId(), req);

        assertEquals(newDiscount, d.getDiscount(), "财务改折扣须落库（V226 setDiscount 遗漏修复）");
        assertFalse(d.isDiscountMasked());
    }

    @AfterEach
    void clearSecurityContext() {
        SecurityContextHolder.clearContext();
    }

    private static void authenticate(String... permissions) {
        SecurityContextHolder.getContext().setAuthentication(
                new TestingAuthenticationToken("test", "n/a", permissions));
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
                null, null, null, null, null, null, null);
    }
}
