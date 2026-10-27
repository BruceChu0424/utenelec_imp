package com.uten.imp.features.master.goods;

import com.uten.imp.features.master.goods.dto.GoodsListItem;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.EmployeeHandoverVisibility;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import jakarta.persistence.TypedQuery;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class GoodsListScopeProjectionTest {
    private static final UUID SELF = UUID.randomUUID();
    private static final UUID HANDOVER = UUID.randomUUID();
    private static final UUID SHARED = UUID.randomUUID();

    private record Case(boolean enabled, boolean admin, Set<String> permissions,
                        OwnerVisibility.OwnerScope scope, List<UUID> owners, List<Boolean> writable) {}

    static Stream<Arguments> permissions() {
        var personal = new OwnerVisibility.OwnerScope(false, Set.of(SELF), Set.of(SELF));
        var handedOver = new OwnerVisibility.OwnerScope(false, Set.of(SELF, HANDOVER), Set.of(SELF, HANDOVER));
        var shared = new OwnerVisibility.OwnerScope(false, Set.of(SELF, SHARED), Set.of(SELF));
        var none = new OwnerVisibility.OwnerScope(false, Set.of(), Set.of());
        return Stream.of(
                Arguments.of("disabled owner isolation", new Case(false, false, Set.of(), none,
                        Arrays.asList(SELF, SHARED, null), List.of(true, true, true))),
                Arguments.of("super administrator", new Case(true, true, Set.of(),
                        new OwnerVisibility.OwnerScope(true, Set.of()), Arrays.asList(SELF, SHARED, null), List.of(true, true, true))),
                Arguments.of("view-all authority", new Case(true, false, Set.of("goods:view:all"),
                        new OwnerVisibility.OwnerScope(true, Set.of()), Arrays.asList(SELF, SHARED, null), List.of(true, true, true))),
                Arguments.of("own records", new Case(true, false, Set.of(), personal,
                        Arrays.asList(SELF, null), List.of(true, true))),
                Arguments.of("formal handover records", new Case(true, false, Set.of(), handedOver,
                        Arrays.asList(HANDOVER, SELF, null), List.of(true, true, true))),
                Arguments.of("explicit read-only sharing", new Case(true, false, Set.of(), shared,
                        Arrays.asList(SHARED, SELF, null), List.of(false, true, true))),
                Arguments.of("no owner grants", new Case(true, false, Set.of(), none,
                        Arrays.asList((UUID) null), List.of(true))),
                Arguments.of("only read-only owner", new Case(true, false, Set.of(),
                        new OwnerVisibility.OwnerScope(false, Set.of(SHARED), Set.of()),
                        Arrays.asList(SHARED, null), List.of(false, true))));
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("permissions")
    void listKeepsTheExistingWritableRulesAndResolvesItsScopeOnce(String scenario, Case example) {
        Fixture fixture = new Fixture(example, false);
        var rows = fixture.service.list(mock(GoodsQueryFilter.class), 1, 100, null, null).getItems();

        assertThat(rows).as(scenario).extracting(GoodsListItem::isWritable).containsExactlyElementsOf(example.writable());
        assertThat(rows).extracting(GoodsListItem::getId)
                .containsExactlyElementsOf(fixture.goods.stream().map(Goods::getId).toList());
        verify(fixture.visibility, times(example.enabled() ? 1 : 0)).evaluate("goods", "goods:view:all");
    }

    @Test
    void aHundredRowsDoNotRepeatTheActualOwnerScopeReadPath() {
        var none = new OwnerVisibility.OwnerScope(false, Set.of(), Set.of());
        Fixture fixture = new Fixture(new Case(true, false, Set.of(), none,
                java.util.Collections.nCopies(100, null), java.util.Collections.nCopies(100, true)), true);

        var result = fixture.service.list(mock(GoodsQueryFilter.class), 1, 100, null, null);

        assertThat(result.getItems()).hasSize(100).allMatch(GoodsListItem::isWritable);
        long reads = fixture.executedSql.stream().filter(sql ->
                sql.contains("FROM user_data_scopes data_scope") || sql.contains("WITH RECURSIVE ranked_edges")).count();
        System.out.println("GOODS-LIST-OWNER-SQL rows=100 statements=" + reads);
        assertThat(reads).isEqualTo(2);
    }

    @Test
    void aLaterListReadsTheNewScopeRatherThanReusingTheEarlierRequest() {
        var owned = new OwnerVisibility.OwnerScope(false, Set.of(SELF), Set.of(SELF));
        Fixture fixture = new Fixture(new Case(true, false, Set.of(), owned,
                List.of(SELF), List.of(true)), false);
        assertThat(fixture.service.list(mock(GoodsQueryFilter.class), 1, 100, null, null).getItems())
                .singleElement().extracting(GoodsListItem::isWritable).isEqualTo(true);
        fixture.scope.set(new OwnerVisibility.OwnerScope(false, Set.of(SELF), Set.of()));

        assertThat(fixture.service.list(mock(GoodsQueryFilter.class), 1, 100, null, null).getItems())
                .singleElement().extracting(GoodsListItem::isWritable).isEqualTo(false);
        verify(fixture.visibility, times(2)).evaluate("goods", "goods:view:all");
    }

    @Test
    void theSingleRecordWriteGuardStillResolvesItsCurrentScopeAfterAList() {
        var owned = new OwnerVisibility.OwnerScope(false, Set.of(SELF), Set.of(SELF));
        Fixture fixture = new Fixture(new Case(true, false, Set.of(), owned,
                List.of(SELF), List.of(true)), false);
        fixture.service.list(mock(GoodsQueryFilter.class), 1, 100, null, null);
        fixture.scope.set(new OwnerVisibility.OwnerScope(false, Set.of(SELF), Set.of()));

        assertThatThrownBy(() -> fixture.service.requireWritable(fixture.goods.getFirst()))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class);
        verify(fixture.visibility, times(2)).evaluate("goods", "goods:view:all");
        verify(fixture.repo, never()).save(any());
    }

    @Test
    void anEmptyPageDoesNotIntroduceRowScopeReads() {
        var none = new OwnerVisibility.OwnerScope(false, Set.of(), Set.of());
        Fixture fixture = new Fixture(new Case(true, false, Set.of(), none, List.of(), List.of()), false);

        assertThat(fixture.service.list(mock(GoodsQueryFilter.class), 1, 100, null, null).getItems()).isEmpty();
        verify(fixture.visibility, times(1)).evaluate("goods", "goods:view:all");
        assertThat(fixture.executedSql).isEmpty();
    }

    @Test
    void bomPageCapabilitiesUseTheSameWritableRuleAndKeepTheirVisibleOwnerFilter() {
        var shared = new OwnerVisibility.OwnerScope(false, Set.of(SELF, SHARED), Set.of(SELF));
        Fixture fixture = new Fixture(new Case(true, false, Set.of(), shared,
                Arrays.asList(SELF, SHARED, HANDOVER, null), List.of()), false);

        var capabilities = fixture.service.visibleWriteCapabilities(fixture.goods);

        assertThat(capabilities).containsOnlyKeys(fixture.goods.get(0).getId(),
                fixture.goods.get(1).getId(), fixture.goods.get(3).getId());
        assertThat(capabilities).containsEntry(fixture.goods.get(0).getId(), true)
                .containsEntry(fixture.goods.get(1).getId(), false)
                .containsEntry(fixture.goods.get(3).getId(), true);
        verify(fixture.visibility, times(1)).evaluate("goods", "goods:view:all");
    }

    private static final class Fixture {
        final GoodsRepository repo = mock(GoodsRepository.class);
        final List<Goods> goods = new ArrayList<>();
        final List<String> executedSql = new ArrayList<>();
        final AtomicReference<OwnerVisibility.OwnerScope> scope;
        final OwnerVisibility visibility;
        final GoodsService service;

        @SuppressWarnings("unchecked")
        Fixture(Case example, boolean realScopeReads) {
            scope = new AtomicReference<>(example.scope());
            for (UUID owner : example.owners()) {
                Goods row = new Goods();
                row.setCode("G-" + goods.size());
                row.setOwnerEmployeeId(owner);
                goods.add(row);
            }
            when(repo.findAll(any(Specification.class), any(Pageable.class)))
                    .thenAnswer(call -> new PageImpl<>(goods, call.getArgument(1), goods.size()));
            EntityManager em = mock(EntityManager.class);
            TypedQuery<UUID> bom = mock(TypedQuery.class);
            when(em.createQuery(anyString(), eq(UUID.class))).thenReturn(bom);
            when(bom.setParameter(anyString(), any())).thenReturn(bom);
            when(bom.getResultList()).thenReturn(List.of());
            when(em.createNativeQuery(anyString())).thenAnswer(call -> {
                String sql = call.getArgument(0);
                Query query = mock(Query.class);
                when(query.setParameter(anyString(), any())).thenReturn(query);
                when(query.getResultList()).thenAnswer(ignored -> {
                    executedSql.add(sql);
                    return List.of();
                });
                return query;
            });
            SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
            when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), SELF, "scope-fixture",
                    example.permissions(), false, true, example.admin())));
            if (realScopeReads) visibility = new OwnerVisibility(current, em, new EmployeeHandoverVisibility(em));
            else {
                visibility = mock(OwnerVisibility.class);
                when(visibility.evaluate("goods", "goods:view:all")).thenAnswer(ignored -> scope.get());
            }
            GoodsMasterRelationshipResolver relationships = mock(GoodsMasterRelationshipResolver.class);
            when(relationships.warehouseNames(any())).thenReturn(Map.of());
            when(relationships.departmentNames(any())).thenReturn(Map.of());
            service = new GoodsService(repo,
                    mock(com.uten.imp.features.master.materialcategory.MaterialCategoryRepository.class),
                    mock(com.uten.imp.features.master.color.ColorRepository.class),
                    mock(com.uten.imp.features.master.unit.UnitRepository.class),
                    mock(com.uten.imp.features.master.mould.MouldRepository.class),
                    mock(com.uten.imp.security.TxSessionVars.class), em,
                    mock(com.uten.imp.common.mastercode.CategoryDrivenCodeService.class), visibility, current,
                    mock(GoodsCostMasker.class), relationships);
            ReflectionTestUtils.setField(ReflectionTestUtils.getField(service, "goodsReadScopePolicy"),
                    "ownerScopeEnabled", example.enabled());
        }
    }
}
