package com.uten.imp.features.stock;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class StockAiWarehouseScopeTest {
    private final EntityManager em = mock(EntityManager.class);
    private final StockBalanceRepository balances = mock(StockBalanceRepository.class);
    private final StockCostMasker costs = mock(StockCostMasker.class);
    private final StockQueryService service = new StockQueryService(balances, em, costs);

    @Test void selectedParentCannotExpandBeyondAuthorizedChildAndBindsChildIdentity() {
        UUID parent = UUID.randomUUID(), own = UUID.randomUUID(), other = UUID.randomUUID();
        Query subtree = mock(Query.class, RETURNS_SELF);
        Query data = mock(Query.class, RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(subtree, data, data);
        when(subtree.getResultList()).thenReturn(List.of(parent, own, other));
        when(data.getResultList()).thenReturn(List.of());
        when(data.getSingleResult()).thenReturn(0L);
        service.instantInventoryRowsInWarehouseScope(filter(parent), Set.of(own), 1, 6, "name", "asc");
        verify(data, times(2)).setParameter("warehouseId", own);
        verify(data, never()).setParameter("warehouseId", parent);
        verify(data, never()).setParameter(eq("scopeIds"), any());
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, times(3)).createNativeQuery(sql.capture());
        assertTrue(sql.getAllValues().get(1).contains("b.warehouse_id = :warehouseId"));
        assertTrue(sql.getAllValues().get(1).contains("COALESCE(i.pre_stocked_warehouse_id, i.warehouse_id) = :warehouseId"));
    }

    @Test void emptyWarehouseScopeSuppressesGoodsAndAllThreeQuantitySources() {
        Query data = mock(Query.class, RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(data);
        when(data.getResultList()).thenReturn(List.of());
        when(data.getSingleResult()).thenReturn(0L);
        assertTrue(service.instantInventoryRowsInWarehouseScope(filter(null), Set.of(), 1, 6, "name", "asc").getItems().isEmpty());
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, times(2)).createNativeQuery(sql.capture());
        assertTrue(sql.getAllValues().stream().allMatch(value -> value.contains("WHERE g.is_deleted = false AND FALSE")));
        assertTrue(sql.getAllValues().stream().allMatch(value -> value.split("AND FALSE", -1).length >= 5));
        verify(data, never()).setParameter(eq("warehouseId"), any());
        verify(data, never()).setParameter(eq("scopeIds"), any());
    }

    @Test void nullAuthorityScopeFailsClosedBeforeQuery() {
        assertThrows(com.uten.imp.common.web.ApiException.class,
                () -> service.instantInventoryRowsInWarehouseScope(filter(null), null, 1, 6, "name", "asc"));
        verifyNoInteractions(em, balances, costs);
    }

    private static StockQueryService.InstantInventoryFilter filter(UUID warehouse) {
        return new StockQueryService.InstantInventoryFilter(null, warehouse, true, false, "MAT", null, null,
                null, null, null, null);
    }
}
