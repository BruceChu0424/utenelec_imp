package com.uten.imp.security;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

class WarehouseObserverAccessTest {
    @Test void outsideDepartmentReaderCanBrowseButDoesNotGainResponsibilityOrAnyWarehouse() {
        var current=mock(SecurityContextCurrentUser.class);
        var warehouses=mock(WarehouseTaskScopePort.class);
        var actor=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"observer",Set.of("stock_doc:view"),false,true,false);
        when(current.get()).thenReturn(Optional.of(actor));
        when(warehouses.access()).thenReturn(new WarehouseTaskScopePort.WarehouseAccess(
                WarehouseTaskScopePort.Role.OTHER,List.of(),WarehouseTaskScopePort.WarehouseTaskScope.NONE,false));
        when(warehouses.current(null)).thenReturn(WarehouseTaskScopePort.WarehouseTaskScope.NONE);
        var policy=new ProductionStockTaskAccessPolicy(current,warehouses);
        assertThat(policy.canBrowseWarehouseTasks()).isTrue();
        assertThat(policy.canAccessWarehouseTasks()).isFalse();
        assertThat(policy.readWarehouseScope()).isSameAs(WarehouseTaskScopePort.WarehouseTaskScope.NONE);
        when(current.get()).thenReturn(Optional.of(new AuthUser(actor.getId(),actor.getEmployeeId(),"observer",Set.of(),false,true,false)));
        assertThat(policy.canBrowseWarehouseTasks()).isFalse();
    }
}
