package com.uten.imp.features.stock;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.application.port.WarehouseTaskScopePort.Role;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseAccess;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** ADR-149: 生产链仓库任务的对象范围委托仓库数据范围的唯一判定, 不再自己按 SUB_WH 子树查一遍。 */
class ProductionStockTaskAccessPolicyTest {

    @Test
    void participantsAreSupervisorsKeepersOrWarehouseMembers() {
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        WarehouseTaskScopePort scopes = mock(WarehouseTaskScopePort.class);
        when(current.get()).thenReturn(Optional.of(staff(UUID.randomUUID(), false)));
        ProductionStockTaskAccessPolicy policy = new ProductionStockTaskAccessPolicy(current, scopes);

        when(scopes.access()).thenReturn(access(Role.OTHER, false));
        assertFalse(policy.canAccessWarehouseTasks());
        when(scopes.access()).thenReturn(access(Role.OTHER, true));
        assertTrue(policy.canAccessWarehouseTasks());
        when(scopes.access()).thenReturn(access(Role.KEEPER, false));
        assertTrue(policy.canAccessWarehouseTasks());
        when(scopes.access()).thenReturn(access(Role.SUPERVISOR, false));
        assertTrue(policy.canAccessWarehouseTasks());
    }

    @Test
    void superAdminRetainsRecoveryAccessWithoutResolvingScope() {
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        WarehouseTaskScopePort scopes = mock(WarehouseTaskScopePort.class);
        when(current.get()).thenReturn(Optional.of(staff(UUID.randomUUID(), true)));

        assertTrue(new ProductionStockTaskAccessPolicy(current, scopes).canAccessWarehouseTasks());
        verify(scopes, never()).access();
    }

    @Test
    void anonymousOrEmployeeLessAccountsNeverAccessWarehouseTasks() {
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        WarehouseTaskScopePort scopes = mock(WarehouseTaskScopePort.class);
        when(current.get()).thenReturn(Optional.empty());
        assertFalse(new ProductionStockTaskAccessPolicy(current, scopes).canAccessWarehouseTasks());
        when(current.get()).thenReturn(Optional.of(staff(null, false)));
        assertFalse(new ProductionStockTaskAccessPolicy(current, scopes).canAccessWarehouseTasks());
        verify(scopes, never()).access();
    }

    private static WarehouseAccess access(Role role, boolean member) {
        return new WarehouseAccess(role, List.of(), WarehouseTaskScope.ALL, member);
    }

    private static AuthUser staff(UUID employeeId, boolean superAdmin) {
        return new AuthUser(
                UUID.randomUUID(), employeeId, "warehouse-test", Set.of("stock_doc:view"),
                false, true, superAdmin);
    }
}
