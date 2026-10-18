package com.uten.imp.features.documents;

import com.uten.imp.application.port.TaskAudiencePort;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.function.Supplier;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class DocumentTaskAudienceCountTest {
    private final UUID self = UUID.randomUUID();
    private final UUID observed = UUID.randomUUID();
    private final EntityManager em = mock(EntityManager.class);
    private final OwnerVisibility owners = mock(OwnerVisibility.class);
    private final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);

    private void actor(String... permissions) {
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), self, "staff",
                Set.of(permissions), false, true, false)));
        when(owners.evaluate(anyString(), anyString())).thenReturn(
                new OwnerVisibility.OwnerScope(false, Set.of(self, observed), Set.of(self)));
    }

    private Query query(Object result) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getSingleResult()).thenReturn(result);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        return query;
    }

    @Test void viewOnlyNeverReceivesDraftOrRejectedWork() {
        actor("sales_quote:view", "sales_shipment:view", "finance_expense:view", "subcontract_order:view");
        assertThat(new DocumentDraftCountQueryService(em, owners, current).counts().salesQuote()).isZero();
        assertThat(new DocumentStatusCountQueryService(em, owners, current).financeRejectedCounts())
                .allSatisfy((key, count) -> assertThat(count).isZero());
        verifyNoInteractions(em, owners);
    }

    @Test void draftWorkExcludesManualReadOnlyOwnersAndOwnerlessRecords() {
        actor("sales_order:view", "sales_order:edit");
        Object[] values = new Object[DocumentDraftCountQueryService.SOURCES.size()];
        values[0] = 2L;
        Query query = query(values);
        assertThat(new DocumentDraftCountQueryService(em, owners, current).counts().salesOrder()).isEqualTo(2);
        verify(query).setParameter("draftOwners_0", Set.of(self));
        verify(em).createNativeQuery(argThat(sql -> sql.contains("o.owner_employee_id IS NOT NULL")
                && sql.contains("o.owner_employee_id IN (:draftOwners_0)")));
    }

    @Test void rejectedWorkRequiresCorrectionRatherThanApprovalAuthority() {
        actor("sales_quote:view", "sales_quote:approve");
        assertThat(new DocumentStatusCountQueryService(em, owners, current).financeRejectedCounts().get("salesQuote"))
                .isZero();
        verifyNoInteractions(em);
    }

    @Test void customerShipmentCorrectionsDoNotSubscribeToOrderShipmentWork() {
        actor("sales_other_shipment:view", "sales_other_shipment:edit");
        Query query = query(new Object[] {3L, 0L, 0L, 0L});
        assertThat(new DocumentStatusCountQueryService(em, owners, current).financeRejectedCounts().get("salesShipment"))
                .isEqualTo(3);
        verify(em).createNativeQuery(argThat(sql -> sql.contains("o.shipment_kind = 'DIRECT_CUSTOMER'")
                && sql.contains("o.owner_employee_id IS NOT NULL")));
        verify(query).setParameter("owners_salesShipment", Set.of(self));
    }

    @Test void directCustomerShipmentReaderGetsOnlyTheExplicitCustomerSlice() {
        actor("sales_other_shipment:view", "sales_other_shipment:edit");
        Query browse = mock(Query.class);
        Query tasks = mock(Query.class);
        when(browse.setParameter(anyString(), any())).thenReturn(browse);
        when(tasks.setParameter(anyString(), any())).thenReturn(tasks);
        when(em.createNativeQuery(anyString())).thenReturn(browse, tasks);
        when(browse.getSingleResult()).thenReturn(new Object[] {4L, 2L, 1L, 3L, 8L, 0L});
        when(tasks.getSingleResult()).thenReturn(new Object[] {2L, 1L, 1L, 2L});
        var service = new DocumentStatusCountQueryService(em, owners, current);
        ReflectionTestUtils.setField(service, "taskAudience", new TaskAudiencePort() {
            @Override public <T> T read(Supplier<T> work) { return work.get(); }
        });
        assertThat(service.counts("salesShipment", "DIRECT_CUSTOMER", null))
                .containsEntry("DRAFT", 4L).containsEntry("ACTIONABLE_DRAFT", 2L);
        verify(browse).setParameter("shipmentKind", "DIRECT_CUSTOMER");
        verify(tasks).setParameter("shipmentKind", "DIRECT_CUSTOMER");
        clearInvocations(em);
        assertThat(service.counts("salesShipment", null, null)).allSatisfy((key, value) -> assertThat(value).isZero());
        verifyNoInteractions(em);
    }

    @Test void browseTotalsRemainSeparateFromActionableSegmentCounts() {
        actor("sales_quote:view", "sales_quote:edit");
        Query browse = mock(Query.class);
        Query tasks = mock(Query.class);
        when(browse.setParameter(anyString(), any())).thenReturn(browse);
        when(tasks.setParameter(anyString(), any())).thenReturn(tasks);
        when(em.createNativeQuery(anyString())).thenReturn(browse, tasks);
        when(browse.getSingleResult()).thenReturn(new Object[] {9L, 4L, 5L, 8L, 1L});
        when(tasks.getSingleResult()).thenReturn(new Object[] {2L, 3L, 1L});
        var service = new DocumentStatusCountQueryService(em, owners, current);
        ReflectionTestUtils.setField(service, "taskAudience", new TaskAudiencePort() {
            @Override public <T> T read(Supplier<T> work) { return work.get(); }
        });
        var result = service.counts("salesQuote", null, null);
        assertThat(result).containsEntry("DRAFT", 9L).containsEntry("FINANCE_REJECTED", 5L)
                .containsEntry("ACTIONABLE_DRAFT", 2L).containsEntry("ACTIONABLE_FINANCE_REJECTED", 1L);
        verify(browse).setParameter("statusOwners", Set.of(self, observed));
        verify(tasks).setParameter("taskStatusOwners", Set.of(self));
    }
}
