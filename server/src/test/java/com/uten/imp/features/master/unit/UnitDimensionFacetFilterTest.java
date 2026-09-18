package com.uten.imp.features.master.unit;

import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.features.master.unit.dto.UnitQueryFilter;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Root;
import org.junit.jupiter.api.Test;
import org.mockito.Answers;
import org.mockito.ArgumentCaptor;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.util.Collection;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 基本单位「计量维度」表头筛选（2026-09-16）：dimension=按
 * unit_measurement_profiles.measurement_dimension 等值（先取命中单位 id 再 IN）；
 * nullFields 含 dimension=筛未设置维度；facets dimension 桶 GROUP BY 维度值、
 * 空值计数=无维度档案的单位数。
 */
class UnitDimensionFacetFilterTest {

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void dimensionFilterConstrainsUnitIdsBeforePagination() {
        UnitRepository repository = mock(UnitRepository.class);
        when(repository.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));
        UUID massUnit = UUID.randomUUID();
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of(massUnit));

        service(em, repository).list(filter("MASS", Set.of()), 1, 20);

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(sql.getValue())
                .contains("from unit_measurement_profiles")
                .contains("measurement_dimension = :dimension");

        ArgumentCaptor<Specification<Unit>> captor = ArgumentCaptor.forClass(Specification.class);
        verify(repository).findAll(captor.capture(), any(Pageable.class));
        Root<Unit> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        captor.getValue().toPredicate(root, null, cb);

        var path = root.get("id");
        ArgumentCaptor<Collection> ids = ArgumentCaptor.forClass(Collection.class);
        verify(path).in(ids.capture());
        assertThat(ids.getValue()).containsExactly(massUnit);
    }

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void dimensionNullFieldFiltersUnitsWithoutMeasurementProfile() {
        UnitRepository repository = mock(UnitRepository.class);
        when(repository.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));
        UUID withProfile = UUID.randomUUID();
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of(withProfile));

        service(em, repository).list(filter(null, Set.of("dimension")), 1, 20);

        ArgumentCaptor<Specification<Unit>> captor = ArgumentCaptor.forClass(Specification.class);
        verify(repository).findAll(captor.capture(), any(Pageable.class));
        Root<Unit> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        captor.getValue().toPredicate(root, null, cb);

        // 未设置维度 = 不在维度档案里的单位（NOT IN 全部已设置 id）。
        ArgumentCaptor<jakarta.persistence.criteria.Predicate> not =
                ArgumentCaptor.forClass(jakarta.persistence.criteria.Predicate.class);
        verify(cb).not(not.capture());
    }

    @Test
    void invalidDimensionIsRejected() {
        EntityManager em = mock(EntityManager.class);
        assertThatThrownBy(() ->
                service(em, mock(UnitRepository.class)).list(filter("HEAVY", Set.of()), 1, 20))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class)
                .hasMessageContaining("计量维度");
    }

    @Test
    void facetsDimensionBucketsGroupByProfileAndCountUnitsWithoutProfile() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        when(query.getSingleResult()).thenReturn(0L);

        service(em, mock(UnitRepository.class)).facets();

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, atLeastOnce()).createNativeQuery(sql.capture());
        assertThat(sql.getAllValues()).anySatisfy(statement -> assertThat(statement)
                .contains("join unit_measurement_profiles p on p.unit_id = u.id")
                .contains("group by p.measurement_dimension"));
        assertThat(sql.getAllValues()).anySatisfy(statement -> assertThat(statement)
                .contains("not exists")
                .contains("(select 1 from unit_measurement_profiles p where p.unit_id = u.id)"));
    }

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void dimensionWithoutMatchesFiltersToEmptyResultNotEverything() {
        UnitRepository repository = mock(UnitRepository.class);
        when(repository.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());

        service(em, repository).list(filter("MASS", Set.of()), 1, 20);

        ArgumentCaptor<Specification<Unit>> captor = ArgumentCaptor.forClass(Specification.class);
        verify(repository).findAll(captor.capture(), any(Pageable.class));
        Root<Unit> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        captor.getValue().toPredicate(root, null, cb);

        // 空命中 = 恒 false（cb.disjunction），绝不退化成"不过滤"。
        verify(cb).disjunction();
        verify(root, org.mockito.Mockito.never()).get(eq("id"));
    }

    private static UnitService service(EntityManager em, UnitRepository repository) {
        return new UnitService(
                repository,
                mock(TxSessionVars.class),
                em,
                mock(MasterCodeService.class));
    }

    private static UnitQueryFilter filter(String dimension, Set<String> nullFields) {
        return new UnitQueryFilter(null, nullFields, null, null, null, dimension);
    }
}
