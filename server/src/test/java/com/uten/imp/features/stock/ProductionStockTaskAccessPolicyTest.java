package com.uten.imp.features.stock;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionStockTaskAccessPolicyTest {

    @Test
    void warehouseSubtreeMembershipIsRequiredForARegularStaffAccount() {
        EntityManager em = mock(EntityManager.class);
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        Query query = mock(Query.class);
        UUID employeeId = UUID.randomUUID();
        when(current.get()).thenReturn(Optional.of(staff(employeeId, false)));
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter("employeeId", employeeId)).thenReturn(query);
        when(query.getSingleResult()).thenReturn(0L, 1L);
        ProductionStockTaskAccessPolicy policy =
                new ProductionStockTaskAccessPolicy(em, current);

        assertFalse(policy.canAccessWarehouseTasks());
        assertTrue(policy.canAccessWarehouseTasks());
        verify(query, times(2)).setParameter("employeeId", employeeId);
    }

    @Test
    void superAdminRetainsRecoveryAccessWithoutADepartmentQuery() {
        EntityManager em = mock(EntityManager.class);
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(
                staff(UUID.randomUUID(), true)));

        assertTrue(new ProductionStockTaskAccessPolicy(
                em, current).canAccessWarehouseTasks());
        verify(em, never()).createNativeQuery(anyString());
    }

    private static AuthUser staff(UUID employeeId, boolean superAdmin) {
        return new AuthUser(
                UUID.randomUUID(), employeeId, "warehouse-test",
                Set.of(), Set.of("stock_doc:view"),
                false, true, superAdmin);
    }
}
