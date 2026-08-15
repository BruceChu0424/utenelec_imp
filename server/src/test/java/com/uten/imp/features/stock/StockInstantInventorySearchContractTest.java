package com.uten.imp.features.stock;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class StockInstantInventorySearchContractTest {

    @Test
    void locationQueryUsesTheSameKeywordAndDeletionContractAsInventoryRows() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any())).thenReturn(query);
        UUID categoryId = UUID.randomUUID();
        when(query.getResultList()).thenReturn(List.of(categoryId));
        StockQueryService service = new StockQueryService(null, null, em);

        var result = service.instantInventoryMatchingCategoryIds(
                "  G-001  ", Set.of(UUID.randomUUID()));

        assertThat(result).containsExactly(categoryId);
        var sql = org.mockito.ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(sql.getValue())
                .contains("g.is_deleted = false")
                .contains("g.name ILIKE :kw", "g.code ILIKE :kw")
                .contains("g.model ILIKE :kw", "g.c_number ILIKE :kw")
                .doesNotContain("g.spec ILIKE", "g.series ILIKE", "auto_created", "status");
        verify(query).setParameter("kw", "%G-001%");
    }

    @Test
    void locationQueryFailsClosedWithoutABoundedTreeScope() {
        StockQueryService service = new StockQueryService(null, null, mock(EntityManager.class));
        assertThatThrownBy(() -> service.instantInventoryMatchingCategoryIds("G", Set.of()))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class);
        assertThatThrownBy(() -> service.instantInventoryMatchingCategoryIds(
                "G", java.util.stream.IntStream.range(0, 33)
                        .mapToObj(ignored -> UUID.randomUUID()).collect(java.util.stream.Collectors.toSet())))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class);
    }
}
