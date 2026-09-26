package com.uten.imp.features.master.warehouse;

import com.uten.imp.application.port.OrganizationReferencePort;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.features.master.warehouse.dto.WarehouseQueryFilter;
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

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 仓库「上级仓库 / 核算」表头筛选（2026-09-16）：
 * ①列表 parentId/accountable 等值过滤（parentId 入 nullFields=筛顶层/独立仓）；
 * ②facets parent 桶自 JOIN 出上级仓名、空值计数=顶层仓；accountable 桶 true/false→是/否。
 */
class WarehouseParentAccountableFilterTest {

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void parentAndAccountableFiltersApplyBeforePagination() {
        WarehouseRepository repository = mock(WarehouseRepository.class);
        when(repository.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));
        WarehouseService service = service(mock(EntityManager.class), repository);

        UUID parent = UUID.randomUUID();
        service.list(new WarehouseQueryFilter(
                null, null, null, null, null, null, parent, Boolean.FALSE), 1, 20);

        ArgumentCaptor<Specification<Warehouse>> captor = ArgumentCaptor.forClass(Specification.class);
        verify(repository).findAll(captor.capture(), any(Pageable.class));
        Root<Warehouse> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        captor.getValue().toPredicate(root, null, cb);

        verify(root).get("parentId");
        verify(cb).equal(any(), eq(parent));
        verify(root).get("accountable");
        verify(cb).equal(any(), eq(Boolean.FALSE));
    }

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void parentNullFieldFiltersTopLevelWarehouses() {
        WarehouseRepository repository = mock(WarehouseRepository.class);
        when(repository.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));

        service(mock(EntityManager.class), repository).list(
                new WarehouseQueryFilter(null, Set.of("parentId"), null, null, null, null, null, null),
                1, 20);

        ArgumentCaptor<Specification<Warehouse>> captor = ArgumentCaptor.forClass(Specification.class);
        verify(repository).findAll(captor.capture(), any(Pageable.class));
        Root<Warehouse> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        captor.getValue().toPredicate(root, null, cb);

        verify(root).get("parentId");
        verify(cb).isNull(any());
    }

    @Test
    void facetsParentBucketsSelfJoinForNamesAndAccountableBucketsLabelYesNo() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        when(query.getSingleResult()).thenReturn(0L);

        service(em, mock(WarehouseRepository.class)).facets();

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, atLeastOnce()).createNativeQuery(sql.capture());
        // parent 桶：自 JOIN warehouses 出上级仓名；空值计数=顶层/独立仓（parent_id is null）。
        assertThat(sql.getAllValues()).anySatisfy(statement -> assertThat(statement)
                .contains("join warehouses parent on parent.id = child.parent_id")
                .contains("group by child.parent_id, parent.name"));
        assertThat(sql.getAllValues()).anySatisfy(statement -> assertThat(statement)
                .contains("parent_id is null")
                .doesNotContain("join warehouses parent"));
        // accountable 桶：is_accountable 分组（label 的 是/否 由 Java 侧映射）。
        assertThat(sql.getAllValues()).anySatisfy(statement -> assertThat(statement)
                .contains("group by is_accountable"));
    }

    private static WarehouseService service(EntityManager em, WarehouseRepository repository) {
        return new WarehouseService(
                repository,
                mock(TxSessionVars.class),
                em,
                mock(MasterCodeService.class),
                mock(OrganizationReferencePort.class),
                mock(WarehouseKeeperService.class));
    }
}
