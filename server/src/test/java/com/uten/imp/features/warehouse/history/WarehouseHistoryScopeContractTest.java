package com.uten.imp.features.warehouse.history;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class WarehouseHistoryScopeContractTest {
    @Test void omittedScopeAlwaysResolvesTheActorsDefaultForListsAndFacets() {
        var em = mock(EntityManager.class);
        var scopes = mock(WarehouseTaskScopePort.class);
        var scope = new WarehouseTaskScopePort.WarehouseTaskScope(true, List.of(UUID.randomUUID()), false);
        when(scopes.current(null)).thenReturn(scope);
        var service = new WarehouseHistoryQueryService(em, mock(EmployeeNameResolver.class), scopes);
        Query count = mock(Query.class, RETURNS_SELF);
        when(count.getSingleResult()).thenReturn(0L);
        when(em.createNativeQuery(anyString())).thenReturn(count);
        assertThat(service.list(WarehouseHistoryType.SUBCONTRACT_RETURN, null, null, null, null, 1, 20).getTotal()).isZero();
        verify(count).setParameter("warehouse_scope", scope.idsCsv());
        Query bill = mock(Query.class, RETURNS_SELF), source = mock(Query.class, RETURNS_SELF);
        when(bill.getResultList()).thenReturn(Collections.singletonList(new Object[]{"VISIBLE", 1L}));
        when(source.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(bill, source);
        var facets = service.facets(WarehouseHistoryType.SUBCONTRACT_WASTE, null, null, null, null);
        assertThat(facets.get("billNo")).hasSize(1);
        verify(bill).setParameter("warehouse_scope", scope.idsCsv());
        verify(source).setParameter("warehouse_scope", scope.idsCsv());
        verify(scopes, times(2)).current(null);
    }

    @Test void outsideWarehouseIsRejectedBeforeAnyHistoricalFactIsRead() {
        var em = mock(EntityManager.class);
        var scopes = mock(WarehouseTaskScopePort.class);
        UUID outside = UUID.randomUUID();
        when(scopes.current(outside)).thenThrow(new ApiException(ErrorCode.FORBIDDEN, "outside"));
        var service = new WarehouseHistoryQueryService(em, mock(EmployeeNameResolver.class), scopes);
        assertThatThrownBy(() -> service.list(WarehouseHistoryType.SUBCONTRACT_WASTE, null, null, null, null,
                1, 20, null, null, null, null, outside)).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> service.facets(WarehouseHistoryType.SUBCONTRACT_WASTE, null, null, null, null, outside))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> service.detail(WarehouseHistoryType.SUBCONTRACT_WASTE, UUID.randomUUID(), outside))
                .isInstanceOf(ApiException.class);
        verifyNoInteractions(em);
    }

    @Test void hiddenHistoricalHeaderCannotTriggerAnUnscopedLineRead() {
        var em = mock(EntityManager.class);
        var scopes = mock(WarehouseTaskScopePort.class);
        var scope = new WarehouseTaskScopePort.WarehouseTaskScope(true, List.of(UUID.randomUUID()), false);
        when(scopes.current(null)).thenReturn(scope);
        var header = mock(Query.class, RETURNS_SELF);
        when(header.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(header);
        var service = new WarehouseHistoryQueryService(em, mock(EmployeeNameResolver.class), scopes);
        assertThatThrownBy(() -> service.detail(WarehouseHistoryType.SUBCONTRACT_RETURN, UUID.randomUUID()))
                .isInstanceOf(ApiException.class).hasMessageContaining("不存在");
        verify(header).setParameter("warehouse_scope", scope.idsCsv());
        verify(em, times(1)).createNativeQuery(anyString());
    }
}
