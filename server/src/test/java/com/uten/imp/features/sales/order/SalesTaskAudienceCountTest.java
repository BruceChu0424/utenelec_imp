package com.uten.imp.features.sales.order;

import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.BusinessTaskContext;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.test.util.ReflectionTestUtils;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class SalesTaskAudienceCountTest {
    @Test void readOnlySalesViewDoesNotBecomeActionableOrOngoingWork() {
        EntityManager em = mock(EntityManager.class);
        var service = service(em, Set.of("sales_order:view"), Set.of(UUID.randomUUID()));
        try (var ignored = BusinessTaskContext.open()) {
            assertThat(service.progressStageCounts()).allSatisfy((key, count) -> assertThat(count).isZero());
        }
        verifyNoInteractions(em);
    }

    @Test void correctionAndShipmentWorkAreSeparateAndUseWritableOwners() {
        UUID self = UUID.randomUUID();
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of(
                new Object[] {"REJECTED", 2L}, new Object[] {"SHIPPABLE", 7L}, new Object[] {"PRODUCING", 3L}));
        var service = service(em, Set.of("sales_order:view", "sales_order:edit"), Set.of(self));
        try (var ignored = BusinessTaskContext.open()) {
            assertThat(service.progressStageCounts()).containsEntry("TASK_REJECTED", 2L)
                    .containsEntry("TASK_SHIPPABLE", 0L).containsEntry("TASK_PRODUCING", 3L);
        }
        verify(query).setParameter("salesTaskOwners", Set.of(self));
        ArgumentCaptor<String> executedSql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(executedSql.capture());
        String sql = executedSql.getValue();
        assertThat(sql)
                .contains("o.owner_employee_id IS NOT NULL", "o.owner_employee_id IN (:salesTaskOwners)")
                .containsPattern("(?i)NOT\\s+[a-z][a-z0-9_]*\\.finance_confirmed");
        var reservationTable = java.util.regex.Pattern.compile(
                "(?i)FROM\\s+stock_reservations(?:\\s+AS)?\\s+([a-z][a-z0-9_]*)\\b").matcher(sql);
        assertThat(reservationTable.find()).as("task availability reads physical reservation rows").isTrue();
        String alias = reservationTable.group(1).toLowerCase(java.util.Locale.ROOT);
        assertThat(sql.replaceAll("\\s+", "").toLowerCase(java.util.Locale.ROOT))
                .contains(alias + ".qty-" + alias + ".consumed_qty-" + alias + ".released_qty")
                .contains("not" + alias + ".is_deleted", alias + ".status=0");
        assertThat(SalesOrderService.progressGroupedSql(
                new com.uten.imp.security.DocumentAccessPolicy.NativeReadScope("1=1", null, Set.of())))
                .contains("SUM(i.reserved_qty)");
    }

    private static SalesOrderService service(EntityManager em, Set<String> permissions, Set<UUID> writable) {
        var current = mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), writable.iterator().next(),
                "sales", permissions, false, true, false)));
        var owners = mock(OwnerVisibility.class);
        var visible = new java.util.HashSet<>(writable);
        visible.add(UUID.randomUUID());
        when(owners.evaluate(anyString(), anyString())).thenReturn(new OwnerVisibility.OwnerScope(false, visible, writable));
        var service = mock(SalesOrderService.class, CALLS_REAL_METHODS);
        ReflectionTestUtils.setField(service, "em", em);
        ReflectionTestUtils.setField(service, "accessPolicy", new SalesDocumentAccessPolicy(owners, current));
        return service;
    }
}
