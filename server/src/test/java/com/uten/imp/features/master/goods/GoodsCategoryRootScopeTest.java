package com.uten.imp.features.master.goods;

import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.mould.MouldRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Root;
import org.junit.jupiter.api.Test;
import org.mockito.Answers;
import org.mockito.ArgumentCaptor;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class GoodsCategoryRootScopeTest {

    private final GoodsRepository goodsRepo = mock(GoodsRepository.class);
    private final MaterialCategoryRepository categoryRepo = mock(MaterialCategoryRepository.class);
    private final GoodsService service = new GoodsService(
            goodsRepo,
            categoryRepo,
            mock(ColorRepository.class),
            mock(UnitRepository.class),
            mock(MouldRepository.class),
            mock(TxSessionVars.class),
            mock(EntityManager.class),
            mock(CategoryDrivenCodeService.class),
            mock(OwnerVisibility.class),
            mock(SecurityContextCurrentUser.class),
            mock(GoodsCostMasker.class),
            mock(GoodsMasterRelationshipResolver.class));

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void expandsEveryRequestedRootAndAppliesTheUnionToTheGoodsQuery() {
        UUID rootA = UUID.randomUUID();
        UUID rootB = UUID.randomUUID();
        UUID leafA = UUID.randomUUID();
        UUID leafB = UUID.randomUUID();
        when(categoryRepo.findSubtree(rootA)).thenReturn(List.of(category(rootA), category(leafA)));
        when(categoryRepo.findSubtree(rootB)).thenReturn(List.of(category(rootB), category(leafB)));
        when(goodsRepo.findAll(anyGoodsSpecification(), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));

        Set<UUID> roots = new LinkedHashSet<>(List.of(rootA, rootB));
        service.list(filter(null, roots, "G-"), 1, 20, null, null);

        verify(categoryRepo).findSubtree(rootA);
        verify(categoryRepo).findSubtree(rootB);
        ArgumentCaptor<Specification<Goods>> captor = ArgumentCaptor.forClass(Specification.class);
        ArgumentCaptor<Pageable> pageableCaptor = ArgumentCaptor.forClass(Pageable.class);
        verify(goodsRepo).findAll(captor.capture(), pageableCaptor.capture());

        List<Sort.Order> orders = pageableCaptor.getValue().getSort().stream().toList();
        assertEquals(List.of("createdAt", "id"),
                orders.stream().map(Sort.Order::getProperty).toList());
        assertEquals(List.of(Sort.Direction.DESC, Sort.Direction.DESC),
                orders.stream().map(Sort.Order::getDirection).toList());

        Root<Goods> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        captor.getValue().toPredicate(root, null, cb);
        verify(root.get("category").get("id")).in(List.of(rootA, leafA, rootB, leafB));
    }

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void invalidExplicitRootsFailClosedInsteadOfFallingBackToAllGoods() {
        UUID missingRoot = UUID.randomUUID();
        when(categoryRepo.findSubtree(missingRoot)).thenReturn(List.of());
        when(goodsRepo.findAll(anyGoodsSpecification(), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));

        service.list(filter(null, Set.of(missingRoot), "G-"), 1, 20, null, null);

        ArgumentCaptor<Specification<Goods>> captor = ArgumentCaptor.forClass(Specification.class);
        verify(goodsRepo).findAll(captor.capture(), any(Pageable.class));
        Root<Goods> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        captor.getValue().toPredicate(root, null, cb);
        verify(cb).disjunction();
    }

    @Test
    void rejectsAmbiguousOrOversizedRootScopesBeforeQuerying() {
        UUID categoryId = UUID.randomUUID();
        assertThrows(ApiException.class, () -> service.list(
                filter(categoryId, Set.of(UUID.randomUUID()), "G-"), 1, 20, null, null));

        Set<UUID> oversized = new LinkedHashSet<>();
        while (oversized.size() <= GoodsService.MAX_CATEGORY_ROOT_IDS) {
            oversized.add(UUID.randomUUID());
        }
        assertThrows(ApiException.class, () -> service.list(
                filter(null, oversized, "G-"), 1, 20, null, null));

        verify(categoryRepo, never()).findSubtree(any(UUID.class));
        verify(goodsRepo, never()).findAll(anyGoodsSpecification(), any(Pageable.class));
    }

    @Test
    void lightweightCategoryLocationRequiresKeywordAndExplicitRootScope() {
        assertThrows(ApiException.class, () -> service.matchingCategoryIds(
                filter(null, Set.of(), "G-")));
        assertThrows(ApiException.class, () -> service.matchingCategoryIds(
                filter(null, Set.of(UUID.randomUUID()), " ")));

        verify(categoryRepo, never()).findSubtree(any(UUID.class));
        verify(goodsRepo, never()).findAll(anyGoodsSpecification(), any(Pageable.class));
    }

    private static MaterialCategory category(UUID id) {
        MaterialCategory category = new MaterialCategory();
        category.setId(id);
        return category;
    }

    private static Specification<Goods> anyGoodsSpecification() {
        return any();
    }

    private static GoodsQueryFilter filter(UUID categoryId, Set<UUID> roots, String keyword) {
        return new GoodsQueryFilter(
                categoryId, roots, keyword, Set.of(),
                null, null, null, null, null, null, null, null,
                null, null, null,
                null, null, null, null, null, null, null);
    }
}
